#!/usr/bin/env bash
# worker.sh (Issue state store version - safe)
set -euo pipefail

# GitHub Issue state store
: "${GITHUB_REPOSITORY:?}"          # e.g. terrada3/wine-temp-man-public
: "${GITHUB_TOKEN:?}"               # must be provided via workflow env
: "${GH_STATE_ISSUE_NUMBER:?}"      # issue number storing state

GH_API="https://api.github.com"
STATE_BEGIN="<!-- STATE_BEGIN -->"
STATE_END="<!-- STATE_END -->"

NOW="$(date +%s)"

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


# ----- state helpers -----
has_off_scheduled() {
  local st; st="$(state_read_json)"
  python3 -c 'import json,sys; st=json.load(sys.stdin); print("1" if isinstance(st.get("off"), dict) else "0")' <<<"$st"
}

get_off_at() {
  local st; st="$(state_read_json)"
  python3 -c 'import json,sys; st=json.load(sys.stdin); off=st.get("off") or {}; v=off.get("off_at"); print("" if v is None else str(v))' <<<"$st"
}

clear_off_only() {
  local st; st="$(state_read_json)"
  local merged
  merged="$(python3 - "$st" <<'PY'
import json,sys
st=json.loads(sys.argv[1] or "{}")
st.pop("off", None)
print(json.dumps(st, ensure_ascii=False))
PY
)"
  state_write_json "$merged"
}

clear_off_and_latch() {
  local st; st="$(state_read_json)"
  local merged
  merged="$(python3 - "$st" <<'PY'
import json,sys
st=json.loads(sys.argv[1] or "{}")
st.pop("off", None)
st.pop("heater_on_at", None)
print(json.dumps(st, ensure_ascii=False))
PY
)"
  state_write_json "$merged"
}

# ===== worker logic =====

# 予約が無ければ何もしない
if [[ "$(has_off_scheduled)" != "1" ]]; then
  echo "worker: no schedule -> exit"
  exit 0
fi

OFF_AT="$(get_off_at)"

# off_at が壊れてたら掃除
if ! [[ "$OFF_AT" =~ ^[0-9]+$ ]]; then
  echo "worker: invalid off_at=$OFF_AT -> removing off schedule" >&2
  clear_off_only
  echo "worker: cleaned invalid off schedule"
  exit 0
fi

if (( NOW < OFF_AT )); then
  remaining=$((OFF_AT - NOW))
  mins=$((remaining / 60))
  secs=$((remaining % 60))
  printf "worker: not yet now=%s off_at=%s remaining=%02d:%02d\n" \
    "$NOW" "$OFF_AT" "$mins" "$secs"
  exit 0
fi

echo "worker: off_at reached now=$NOW off_at=$OFF_AT -> press (toggle) to stop heating"

if ./press.sh; then
  # OFFを押せたら、予約とラッチを両方消す
  clear_off_and_latch
  echo "worker: cleared schedule + latch"
  exit 0
else
  rc=$?
  echo "worker: press OFF failed (rc=$rc) -> keep schedule+latch (will retry next tick)" >&2
  exit $rc
fi
