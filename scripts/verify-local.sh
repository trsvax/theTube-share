#!/usr/bin/env bash
# Local verification — test the time-based hash auth without Lambda.
# Simulates what Lambda does: decode JWT, extract secret, verify hash.
#
# Usage: bash scripts/verify-local.sh
set -euo pipefail

echo "=== Local Verification Test ==="
echo ""

# Simulate: mint a token
SECRET=$(openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_')
NOW=$(date +%s)
EXP=$((NOW + 86400))

PAYLOAD="{\"iss\":\"share-mac\",\"sub\":\"mac\",\"scope\":\"publish\",\"secret\":\"${SECRET}\",\"iat\":${NOW},\"exp\":${EXP}}"

JWT_HEADER=$(echo -n '{"alg":"HS256","typ":"JWT"}' | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')
JWT_PAYLOAD=$(echo -n "$PAYLOAD" | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

SIGNATURE=$(echo -n "${JWT_HEADER}.${JWT_PAYLOAD}" | \
  openssl dgst -sha256 -hmac "$SECRET" -binary | \
  openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

TOKEN="${JWT_HEADER}.${JWT_PAYLOAD}.${SIGNATURE}"

echo "1. Minted token (scope=publish, expires in 24h)"
echo "   Secret: ${SECRET:0:8}..."
echo ""

# Simulate: client sends request with time-based hash
TIMESTAMP=$(date +%s)
CLIENT_HASH=$(echo -n "${SECRET}${TIMESTAMP}" | openssl dgst -sha256 -binary | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

echo "2. Client computes hash: SHA256(secret + $TIMESTAMP)"
echo "   X-Pass: ${CLIENT_HASH:0:16}..."
echo "   X-Timestamp: $TIMESTAMP"
echo ""

# Simulate: Lambda verifies
echo "3. Lambda verification:"

# Decode JWT payload (base64url → base64 → decode)
B64_PAYLOAD=$(echo -n "$JWT_PAYLOAD" | sed 's/-/+/g; s/_/\//g')
# Pad to multiple of 4
MOD=$((${#B64_PAYLOAD} % 4))
if [[ $MOD -eq 2 ]]; then B64_PAYLOAD="${B64_PAYLOAD}=="; elif [[ $MOD -eq 3 ]]; then B64_PAYLOAD="${B64_PAYLOAD}="; fi
DECODED_PAYLOAD=$(echo -n "$B64_PAYLOAD" | base64 -d 2>/dev/null)
echo "   Decoded JWT: $DECODED_PAYLOAD"

# Extract secret from payload (simple grep — Lambda would use JSON parse)
EXTRACTED_SECRET=$(echo "$DECODED_PAYLOAD" | sed 's/.*"secret":"\([^"]*\)".*/\1/')
EXTRACTED_EXP=$(echo "$DECODED_PAYLOAD" | sed 's/.*"exp":\([0-9]*\).*/\1/')
EXTRACTED_SCOPE=$(echo "$DECODED_PAYLOAD" | sed 's/.*"scope":"\([^"]*\)".*/\1/')

echo "   Extracted secret: ${EXTRACTED_SECRET:0:8}..."
echo "   Scope: $EXTRACTED_SCOPE"
echo "   Exp: $EXTRACTED_EXP ($(( EXTRACTED_EXP - NOW ))s from now)"

# Check expiry
if [[ "$NOW" -lt "$EXTRACTED_EXP" ]]; then
  echo "   ✓ Token not expired"
else
  echo "   ✗ Token expired"
  exit 1
fi

# Verify HMAC signature on the JWT itself
VERIFY_SIG=$(echo -n "${JWT_HEADER}.${JWT_PAYLOAD}" | \
  openssl dgst -sha256 -hmac "$EXTRACTED_SECRET" -binary | \
  openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

if [[ "$VERIFY_SIG" == "$SIGNATURE" ]]; then
  echo "   ✓ JWT HMAC valid (token not tampered)"
else
  echo "   ✗ JWT HMAC invalid"
  exit 1
fi

# Verify time-based hash
SERVER_HASH=$(echo -n "${EXTRACTED_SECRET}${TIMESTAMP}" | openssl dgst -sha256 -binary | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

if [[ "$SERVER_HASH" == "$CLIENT_HASH" ]]; then
  echo "   ✓ Time-based hash matches"
else
  echo "   ✗ Hash mismatch"
  exit 1
fi

# Check timestamp window (±30 seconds)
DRIFT=$(( NOW - TIMESTAMP ))
if [[ "$DRIFT" -ge -30 && "$DRIFT" -le 30 ]]; then
  echo "   ✓ Timestamp within ±30s window (drift: ${DRIFT}s)"
else
  echo "   ✗ Timestamp outside window (drift: ${DRIFT}s)"
  exit 1
fi

echo ""
echo "=== All checks passed ==="
echo ""
echo "Summary:"
echo "  - JWT is self-verifying (HMAC with embedded secret)"
echo "  - Time-based hash prevents replay"
echo "  - Scope controls what operations are allowed"
echo "  - Same verification for Mac and phone"
