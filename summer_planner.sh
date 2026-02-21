#!/usr/bin/env bash
# summer_planner.sh
set -euo pipefail

# ====== config ======
THRESH_COOL_ON="12.0"     # > 14℃ で冷房ON（press）※一度だけ
THRESH_COOL_OFF="8.0"     # < 8℃ で冷房OFF（press）※自分がONにした時だけ
# ※もし「8℃を超えたらoff」を本当にやりたいなら、下の判定 lt を gt に変える

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_TOKEN:?}"
: "${GH_STATE_ISSUE_NUMBER:?}"

GH_API="https://api.github.com"
STATE_BEGIN="<!-- STATE_BEGIN -->"
STATE_END="<!-- STATE_END -->"

NOW="$(date +%s)"
TEMP="$(./get_temp.sh)"

echo "summer_planner: now=$NOW temp=$TEMP"

# float compare helpers
gt() { (( $(echo "$1 > $2" | bc -l) )); }
lt() { (( $(echo "$1 < $2" | bc -l) )); }

# ----- GitHub Issue state store helpers (safe: python -c only) -----
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
  python3 -c 'import json,sys; json.loads(sys.argv[1])' "$new_json" >/dev/null

  local body updated
  body="$(issue_get_body)"
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

# ----- summer state accessors -----
get_cooler_on_at() {
  local st; st="$(state_read_json)"
  python3 -c 'import json,sys; st=json.load(sys.stdin); print(st.get("cooler_on_at",""))' <<<"$st"
}

set_cooler_on_at() {
  local on_at="$1"
  local st merged
  st="$(state_read_json)"
  merged="$(python3 - "$st" "$on_at" <<'PY'
import json,sys
st=json.loads(sys.argv[1] or "{}")
st["cooler_on_at"]=int(sys.argv[2])
# 念のため、古いOFF予約が残ってたら消す
st.pop("cool_off", None)
print(json.dumps(st, ensure_ascii=False))
PY
)"
  state_write_json "$merged"
}

has_cool_off_scheduled() {
  local st; st="$(state_read_json)"
  python3 -c 'import json,sys; st=json.load(sys.stdin); print("1" if isinstance(st.get("cool_off"), dict) else "0")' <<<"$st"
}

set_cool_off_now() {
  local st merged
  st="$(state_read_json)"
  merged="$(python3 - "$st" "$NOW" "$TEMP" <<'PY'
import json,sys
st=json.loads(sys.argv[1] or "{}")
now=int(sys.argv[2])
temp=float(sys.argv[3])
st["cool_off"]={
  "reason":"temp_low",
  "off_at": now,
  "created_at": now,
  "temp": temp
}
print(json.dumps(st, ensure_ascii=False))
PY
)"
  state_write_json "$merged"
}

# ====== COOL ON: temp high -> press ON once ======
if gt "$TEMP" "$THRESH_COOL_ON"; then
  COOLER_ON_AT="$(get_cooler_on_at)"
  if [[ -n "$COOLER_ON_AT" ]]; then
    echo "summer_planner: temp high but already latched cooler ON (cooler_on_at=$COOLER_ON_AT) -> skip"
    exit 0
  fi

  echo "summer_planner: temp high -> press COOL ON now (toggle press)"
  if ./press.sh; then
    set_cooler_on_at "$NOW"
    echo "summer_planner: cooler ON latched -> cooler_on_at=$NOW"
    exit 0
  else
    rc=$?
    echo "summer_planner: press failed (rc=$rc) -> NOT latching" >&2
    exit $rc
  fi
fi

# ====== COOL OFF: temp low -> schedule OFF only if we turned it ON ======
# ここが「8℃未満でOFF」判定
if lt "$TEMP" "$THRESH_COOL_OFF"; then
  COOLER_ON_AT="$(get_cooler_on_at)"
  if [[ -z "$COOLER_ON_AT" ]]; then
    echo "summer_planner: temp low but cooler_on_at not set -> do nothing (toggle safety)"
    exit 0
  fi

  if [[ "$(has_cool_off_scheduled)" == "1" ]]; then
    echo "summer_planner: cool_off already scheduled -> skip"
    exit 0
  fi

  echo "summer_planner: temp low -> schedule COOL OFF now"
  set_cool_off_now
  exit 0
fi

echo "summer_planner: no action needed"
