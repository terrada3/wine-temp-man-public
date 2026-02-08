#!/usr/bin/env bash
set -euo pipefail

# ====== config ======
THRESH_LOW="9.0"     # <= 9.0 で即時ON（press）※一度だけ
THRESH_HIGH="14.1"   # > 14.1 で 240秒後OFF予約（press）※heater_onラッチがある時だけ
OFF_DELAY=240        # seconds

STATE_DIR="state"
STATE_OFF="${STATE_DIR}/wine_cave.json"  # OFF予約
LATCH_ON="${STATE_DIR}/heater_on"        # 「自分がONにした」ラッチ

mkdir -p "$STATE_DIR"

NOW="$(date +%s)"
TEMP="$(./get_temp.sh)"

echo "planner: now=$NOW temp=$TEMP"

# float compare helpers
gt() { (( $(echo "$1 > $2" | bc -l) )); }
le() { (( $(echo "$1 <= $2" | bc -l) )); }

# ----- git helpers (persist state into repo) -----
git_setup() {
  git config user.name  "wine-bot"
  git config user.email "wine-bot@users.noreply.github.com"
}

git_push_state() {
  # commit が無いときに落ちないようにする
  git_setup
  git add "$STATE_DIR" || true
  git commit -m "$1" || true
  git push || true
}

# ====== LOW: immediate ON (latched) ======
if le "$TEMP" "$THRESH_LOW"; then
  if [[ -f "$LATCH_ON" ]]; then
    echo "planner: low temp but already latched ON -> skip press"
    exit 0
  fi

  echo "planner: low temp -> press ON now"

  if ./press.sh; then
    echo "$NOW" > "$LATCH_ON"
    echo "planner: ON latched -> $LATCH_ON"

    # 低温側では OFF予約は作らない（あなたの方針）
    git_push_state "latch: heater ON at $NOW (temp=$TEMP)"
    exit 0
  else
    rc=$?
    echo "planner: press failed (rc=$rc) -> NOT latching / NOT pushing" >&2
    exit $rc
  fi
fi

# ====== HIGH: schedule OFF only if we turned it ON ======
if gt "$TEMP" "$THRESH_HIGH"; then
  if [[ ! -f "$LATCH_ON" ]]; then
    # システムがONにしたわけじゃないなら、トグル事故防止のため何もしない
    echo "planner: temp high but heater_on latch not set -> do nothing"
    exit 0
  fi

  if [[ -f "$STATE_OFF" ]]; then
    OFF_AT_EXISTING="$(jq -r '.off_at' "$STATE_OFF" 2>/dev/null || true)"
    echo "planner: off already scheduled (off_at=$OFF_AT_EXISTING) -> skip"
    exit 0
  fi

  OFF_AT=$((NOW + OFF_DELAY))

  jq -n \
    --arg reason "temp_high" \
    --argjson off_at "$OFF_AT" \
    --argjson created_at "$NOW" \
    --arg temp "$TEMP" \
    '{
      reason: $reason,
      off_at: $off_at,
      created_at: $created_at,
      temp: ($temp|tonumber)
    }' > "$STATE_OFF"

  echo "planner: scheduled OFF at off_at=$OFF_AT (in ${OFF_DELAY}s)"
  git_push_state "schedule: OFF at $OFF_AT (created_at=$NOW temp=$TEMP)"
  exit 0
fi

echo "planner: no action needed"
