#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="state"
STATE_OFF="${STATE_DIR}/wine_cave.json"
LATCH_ON="${STATE_DIR}/heater_on"

NOW="$(date +%s)"

# ----- git helpers -----
git_setup() {
  git config user.name  "wine-bot"
  git config user.email "wine-bot@users.noreply.github.com"
}

git_push_state() {
  git_setup
  git add "$STATE_DIR" || true
  git commit -m "$1" || true
  git push || true
}

# 予約が無ければ何もしない
if [[ ! -f "$STATE_OFF" ]]; then
  echo "worker: no schedule -> exit"
  exit 0
fi

OFF_AT="$(jq -er '.off_at' "$STATE_OFF" 2>/dev/null || true)"
if ! [[ "$OFF_AT" =~ ^[0-9]+$ ]]; then
  echo "worker: invalid off_at=$OFF_AT -> removing $STATE_OFF" >&2
  rm -f "$STATE_OFF"
  git_push_state "cleanup: invalid off_at removed"
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
  # OFFを押せたら、予約とラッチを両方消す（ここが肝）
  rm -f "$STATE_OFF" "$LATCH_ON"
  echo "worker: cleared schedule + latch"

  git_push_state "done: pressed OFF at $NOW (off_at=$OFF_AT); cleared schedule+latch"
  exit 0
else
  rc=$?
  echo "worker: press OFF failed (rc=$rc) -> keep schedule+latch (will retry next tick)" >&2
  exit $rc
fi
