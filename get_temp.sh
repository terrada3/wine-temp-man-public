#!/usr/bin/env bash
set -euo pipefail

# ===== 必須環境変数チェック =====
: "${SWITCHBOT_TOKEN:?SWITCHBOT_TOKEN not set}"
: "${SWITCHBOT_SECRET:?SWITCHBOT_SECRET not set}"
: "${DEVICE_ID:?DEVICE_ID not set}"

TOKEN="$SWITCHBOT_TOKEN"
SECRET="$SWITCHBOT_SECRET"

# ===== timestamp (ms) =====
t="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

# ===== nonce =====
nonce="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

# ===== sign = HMAC(secret, token + t + nonce) =====
sign="$(python3 - <<PY
import hmac, hashlib, base64
token="$TOKEN"
secret="$SECRET"
t="$t"
nonce="$nonce"
msg=(token + t + nonce).encode("utf-8")
sig=hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).digest()
print(base64.b64encode(sig).decode())
PY
)"

# ===== temperature 取得 =====
temp="$(
  curl -sS "https://api.switch-bot.com/v1.1/devices/${DEVICE_ID}/status" \
    -H "Authorization: ${TOKEN}" \
    -H "t: ${t}" \
    -H "nonce: ${nonce}" \
    -H "sign: ${sign}" \
    -H "Content-Type: application/json" \
  | jq -er '.body.temperature'
)"

echo "$temp"