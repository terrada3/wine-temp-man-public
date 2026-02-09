#!/usr/bin/env bash
# planner.sh (Issue state store version - safe)
set -euo pipefail

# ====== config ======
THRESH_LOW="9.0"     # <= 9.0 で即時ON（press）※一度だけ
THRESH_HIGH="14.1"   # > 14.1 で 240秒後OFF予約（press）※heater_onラッチがある時だけ
OFF_DELAY=240        # seconds

# GitHub Issue state store
: "${GITHUB_REPOSITORY:?}"          # e.g. terrada3/wine-temp-man-public
: "${GITHUB_TOKEN:?}"               # must be provided via workflow env
: "${GH_STATE_ISSUE_NUMBER:?}"      # issue number storing state

GH_API="https://api.github.com"
STATE_BEGIN="<!-- STATE_BEGIN -->"
STATE_END="<!-- STATE_END -->"

NOW="$(date +%s)"
TEMP="$(./get_temp.sh)"

echo "planner: now=$NOW temp=$TEMP"

# float compare helpers
gt() { (( $(echo "$1 > $2" | bc -l) )); }
le() { (( $(echo "$1 <= $2" | bc -l) )); }

# ----- GitHub Issue state store helpers (safe) -----
gh_api() {
  if [[ $# -lt 2 ]]; then
    echo "gh_api: missing args" >&2
    return 2
  fi
  local method="$1"; shift
  local url="$1"; shift
  curl -sS -X "$method" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url" "$@"
}

issue_get_body() {
  gh_api GET "${GH_API}/repos/${GITHUB_REPOSITORY}/issues/${GH_STATE_ISSUE_NUMBER}" \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("body") or ""))'
}

state_read_json() {
  local body; body="$(issue_get_body)"
  STATE_BEGIN="$STATE_BEGIN" STATE_END="$STATE_END" \
  python3 -c '
import os,re,sys,json
body=sys.stdin.read()
begin=re.escape(os.environ["STATE_BEGIN"])
end=re.escape(os.environ["STATE_END"])
m=re.search(begin+r"(.*?)"+end, body, re.S)
if not m:
  print("{}"); sys.exit(0)
raw=m.group(1).strip()
try:
  json.loads(raw); print(raw)
except Exception:
  print("{}")
' <<<"$body"
}

state_write_json() {
  local new_json="$1"

  # validate json
  python3 -c 'import json,sys; json.loads(sys.argv[1])' "$new_json" >/dev/null

  local body
  body="$(issue_get_body)"

  local updated
  updated="$(
    STATE_BEGIN="$STATE_BEGIN" STATE_END="$STATE_END" NEW_JSON="$new_json" \
    python3 -c '
import os,re,sys

body = sys.stdin.read()
begin = os.environ["STATE_BEGIN"]
end   = os.environ["STATE_END"]
new_json = os.environ["NEW_JSON"]

block = f"{begin}\n{new_json}\n{end}"

if begin in body and end in body:
    body = re.sub(re.escape(begin)+r".*?"+re.escape(end),
                  block, body, flags=re.S)
else:
    body = (body.rstrip()+"\n\n" if body.strip() else "") + block + "\n"

print(body)
' <<<"$body"
  )"

  gh_api PATCH "${GH_API}/repos/${GITHUB_REPOSITORY}/issues/${GH_STATE_ISSUE_NUMBER}" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"body": sys.stdin.read()}))' <<<"$updated")" \
    >/dev/null
}


# ----- state accessors -----
get_latch_on() {
  local st; st="$(state_read_json)"
  python3 -c 'import json,sys; st=json.load(sys.stdin); print(st.get("heater_on_at",""))' <<<"$st"
}

set_latch_on() {
  local on_at="$1"
  local st; st="$(state_read_json)"
  local merged
  merged="$(python3 - "$st" "$on_at" <<'PY'
import json,sys
st=json.loads(sys.argv[1] or "{}")
on_at=int(sys.argv[2])
st["heater_on_at"]=on_at
# 低温側では OFF予約は作らない方針（念のため残ってたら消す）
st.pop("off", None)
print(json.dumps(st, ensure_ascii=False))
PY
)"
  state_write_json "$merged"
}

has_off_scheduled() {
  local st; st="$(state_read_json)"
  python3 -c 'import json,sys; st=json.load(sys.stdin); print("1" if isinstance(st.get("off"), dict) else "0")' <<<"$st"
}

get_off_at() {
  local st; st="$(state_read_json)"
  python3 -c 'import json,sys; st=json.load(sys.stdin); off=st.get("off") or {}; v=off.get("off_at"); print("" if v is None else str(v))' <<<"$st"
}

set_off_schedule() {
  local off_at="$1"
  local st; st="$(state_read_json)"
  local merged
  merged="$(python3 - "$st" "$off_at" "$NOW" "$TEMP" <<'PY'
import json,sys
st=json.loads(sys.argv[1] or "{}")
off_at=int(sys.argv[2])
now=int(sys.argv[3])
temp=float(sys.argv[4])
st["off"]={
  "reason": "temp_high",
  "off_at": off_at,
  "created_at": now,
  "temp": temp
}
print(json.dumps(st, ensure_ascii=False))
PY
)"
  state_write_json "$merged"
}

# ====== LOW: immediate ON (latched) ======
if le "$TEMP" "$THRESH_LOW"; then
  LATCH_ON_AT="$(get_latch_on)"
  if [[ -n "$LATCH_ON_AT" ]]; then
    echo "planner: low temp but already latched ON (heater_on_at=$LATCH_ON_AT) -> skip press"
    exit 0
  fi

  echo "planner: low temp -> press ON now"

  if ./press.sh; then
    set_latch_on "$NOW"
    echo "planner: ON latched in issue -> heater_on_at=$NOW"
    exit 0
  else
    rc=$?
    echo "planner: press failed (rc=$rc) -> NOT latching" >&2
    exit $rc
  fi
fi

# ====== HIGH: schedule OFF only if we turned it ON ======
if gt "$TEMP" "$THRESH_HIGH"; then
  LATCH_ON_AT="$(get_latch_on)"
  if [[ -z "$LATCH_ON_AT" ]]; then
    # システムがONにしたわけじゃないなら、トグル事故防止のため何もしない
    echo "planner: temp high but heater_on latch not set -> do nothing"
    exit 0
  fi

  if [[ "$(has_off_scheduled)" == "1" ]]; then
    OFF_AT_EXISTING="$(get_off_at)"
    echo "planner: off already scheduled (off_at=$OFF_AT_EXISTING) -> skip"
    exit 0
  fi

  OFF_AT=$((NOW + OFF_DELAY))
  set_off_schedule "$OFF_AT"
  echo "planner: scheduled OFF at off_at=$OFF_AT (in ${OFF_DELAY}s)"
  exit 0
fi

echo "planner: no action needed"
