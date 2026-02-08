#!/usr/bin/env bash
set -euo pipefail

: "${SWITCHBOT_TOKEN:?not set}"
: "${SWITCHBOT_SECRET:?not set}"
: "${BOT_DEVICE_ID:?not set}"

TOKEN="$SWITCHBOT_TOKEN"
SECRET="$SWITCHBOT_SECRET"
DEVICE_ID="$BOT_DEVICE_ID"

t="$(python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
)"

nonce="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

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

url="https://api.switch-bot.com/v1.1/devices/${DEVICE_ID}/commands"
payload='{"command":"press","parameter":"default","commandType":"command"}'

tmp="$(mktemp)"
cleanup(){ rm -f "$tmp"; }
trap cleanup EXIT

# -f でHTTP 4xx/5xxを失敗扱いに
# タイムアウトと軽いリトライ（瞬断対策）
http_code="$(
  curl -sS -f \
    --connect-timeout 5 \
    --max-time 15 \
    --retry 2 \
    --retry-delay 1 \
    --retry-all-errors \
    -o "$tmp" \
    -w "%{http_code}" \
    -X POST "$url" \
    -H "Authorization: ${TOKEN}" \
    -H "t: ${t}" \
    -H "nonce: ${nonce}" \
    -H "sign: ${sign}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
  || echo "curl_failed"
)"

resp="$(cat "$tmp" 2>/dev/null || true)"

if [[ "$http_code" == "curl_failed" ]]; then
  echo "press: curl failed (network/timeout). device=${DEVICE_ID}" >&2
  exit 10
fi

if [[ "$http_code" != "200" ]]; then
  echo "press: HTTP ${http_code}. body=${resp}" >&2
  exit 11
fi

# JSONとして解釈できるか
if ! echo "$resp" | jq -e . >/dev/null 2>&1; then
  echo "press: invalid JSON. body=${resp}" >&2
  exit 12
fi

status_code="$(echo "$resp" | jq -r '.statusCode // empty')"
message="$(echo "$resp" | jq -r '.message // empty')"

if [[ "$status_code" != "100" ]]; then
  echo "press: SwitchBot error statusCode=${status_code} message=${message} body=${resp}" >&2
  exit 13
fi

echo "pressed: device=${DEVICE_ID}"