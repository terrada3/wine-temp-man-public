#!/usr/bin/env bash
set -euo pipefail

# ====== config ======
THRESH_LOW="9.0"     # <= 9.0 で即時ON（press）※一度だけ
THRESH_HIGH="14.1"   # > 14.1 で 240秒後OFF予約（press）※heater_onラッチがある時だけ
OFF_DELAY=240        # seconds

# GitHub Issue state store
: "${GITHUB_REPOSITORY:?}"          # e.g. terrada3/wine-temp-man-public
: "${GITHUB_TOKEN:?}"               # provided by Actions
: "${GH_STATE_ISSUE_NUMBER:?}"      # set in workflow env/vars

GH_API="https://api.github.com"
STATE_BEGIN="<!-- STATE_BEGIN -->"
STATE_END="<!-- STATE_END -->"

NOW="$(date +%s)"
TEMP="$(./get_temp.sh)"

echo "planner: now=$NOW temp=$TEMP"

# float compare helpers
gt() { (( $(echo "$1 > $2" | bc -l) )); }
le() { (( $(echo "$1 <= $2" | bc -l) )); }

# ----- GitHub API helpers -----
gh_api() {
  local method="$1"; shift
  local url="$1"; shift
  curl -sS -X "$method" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${url}" "$@"
}

issue_get_body() {
  gh_api GET "${GH_API}/repos/${GITHUB_REPOSITORY}/issues/${GH_STATE_ISSUE_NUMBER}" \
    | python3 - <<'PY'
import json,sys
print(json.load(sys.stdin).get("body") or "")
PY
}

state_read_json() {
  local body; body="$(issue_get_body)"
  python3 - <<PY
import re,sys,json
body=sys.stdin.read()
begin=re.escape("${STATE_BEGIN}")
end=re.escape("${STATE_END}")
m=re.search(begin+r"(.*?)"+end, body, re.S)
if not m:
  print("{}"); sys.exit(0)
raw=m.group(1).strip()
try:
  json.loads(raw)
  print(raw)
except Exception:
  print("{}")
PY <<<"$body"
}

state_write_json() {
  local new_json="$1"
  # validate json
  python3 - <<'PY' <<<"$new_json" >/dev/null
import json,sys
json.load(sys.stdin)
PY

  local body; body="$(issue_get_body)"
  local updated
  updated="$(python3 - <<PY
import re,sys
body=sys.stdin.read()
begin="${STATE_BEGIN}"
end="${STATE_END}"
new_json=${new_json!r}
block=f"{begin}\n{new_json}\n{end}"

if begin in body and end in body:
  body=re.sub(re.escape(begin)+r".*?"+re.escape(end), block, body, flags=re.S)
else:
  body=(body.rstrip()+"\n\n" if body.strip() else "") + block + "\n"
print(body)
PY <<<"$body")"

  gh_api PATCH "${GH_API}/repos/${GITHUB_REPOSITORY}/issues/${GH_STATE_ISSUE_NUMBER}" \
    -d "$(python3 - <<PY
import json,sys
print(json.dumps({"body": sys.stdin.read()}))
PY <<<"$updated")" >/dev/null
}

# ----- state accessors -----
get_latch_on() {
  local st; st="$(state_read_json)"
  python3 - <<'PY' <<<"$st"
import json,sys
st=json.load(sys.stdin)
print(st.get("heater_on_at",""))
PY
}

set_latch_on() {
  local on_at="$1"
  local st; st="$(state_read_json)"
  python3 - <<PY <<<"$st" | state_write_json "$(cat)"
import json,sys
st=json.load(sys.stdin)
st["heater_on_at"]=int("${on_at}")
# OFF予約は低温側では作らない方針なので残ってたら消す（念のため）
st.pop("off", None)
print(json.dumps(st, ensure_ascii=False))
PY
}

has_off_scheduled() {
  local st; st="$(state_read_json)"
  python3 - <<'PY' <<<"$st"
import json,sys
st=json.load(sys.stdin)
print("1" if isinstance(st.get("off"), dict) else "0")
PY
}

get_off_at() {
  local st; st="$(state_read_json)"
  python3 - <<'PY' <<<"$st"
import json,sys
st=json.load(sys.stdin)
off=st.get("off") or {}
print(off.get("off_at",""))
PY
}

set_off_schedule() {
  local off_at="$1"
  local st; st="$(state_read_json)"
  python3 - <<PY <<<"$st" | state_write_json "$(cat)"
import json,sys
st=json.load(sys.stdin)
st["off"]={
  "reason": "temp_high",
  "off_at": int("${off_at}"),
  "created_at": int("${NOW}"),
  "temp": float("${TEMP}")
}
print(json.dumps(st, ensure_ascii=False))
PY
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