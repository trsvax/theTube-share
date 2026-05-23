#!/usr/bin/env bash
# Mint a token for any device (Mac or phone).
# Creates an encrypted JWT with an embedded secret.
# The secret also goes in Keychain (Mac) or Shortcut (phone).
#
# Usage:
#   bash scripts/mint-token.sh --device mac --scope publish --days 365
#   bash scripts/mint-token.sh --device iphone --scope capture --days 90
#
# Requires: openssl, security (macOS Keychain)
set -euo pipefail

DEVICE="" SCOPE="" DAYS=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --device) DEVICE="$2"; shift 2 ;;
    --scope)  SCOPE="$2"; shift 2 ;;
    --days)   DAYS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$DEVICE" ]] && { echo "Required: --device (mac, iphone)"; exit 1; }
[[ -z "$SCOPE" ]] && { echo "Required: --scope (capture, publish)"; exit 1; }
[[ -z "$DAYS" ]] && {
  if [[ "$DEVICE" == "mac" ]]; then DAYS=365; else DAYS=90; fi
}

NOW=$(date +%s)
EXP=$((NOW + DAYS * 86400))
EXP_DATE=$(date -r "$EXP" "+%Y-%m-%d")

# Generate a random secret (32 bytes, base64url — strong enough for HMAC)
SECRET=$(openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_')

echo "=== Mint Token ==="
echo "  Device:  $DEVICE"
echo "  Scope:   $SCOPE"
echo "  Expires: $EXP_DATE ($DAYS days)"
echo ""

# Build JWT payload
PAYLOAD="{\"iss\":\"share-${DEVICE}\",\"sub\":\"${DEVICE}\",\"scope\":\"${SCOPE}\",\"secret\":\"${SECRET}\",\"iat\":${NOW},\"exp\":${EXP}}"

# JWT Header (HS256 — HMAC with the embedded secret)
JWT_HEADER=$(echo -n '{"alg":"HS256","typ":"JWT"}' | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')
JWT_PAYLOAD=$(echo -n "$PAYLOAD" | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

# Sign with HMAC-SHA256 using the secret itself as the signing key
# This means the token is self-verifying: Lambda decrypts → gets secret → verifies HMAC
SIGN_INPUT="${JWT_HEADER}.${JWT_PAYLOAD}"
SIGNATURE=$(echo -n "$SIGN_INPUT" | \
  openssl dgst -sha256 -hmac "$SECRET" -binary | \
  openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

TOKEN="${SIGN_INPUT}.${SIGNATURE}"

echo ""
echo "=== Token ==="
echo ""
echo "$TOKEN"
echo ""
echo "=== Secret ==="
echo ""
echo "$SECRET"
echo ""

# Store token and secret in Keychain for Mac usage
if [[ "$DEVICE" == "mac" ]]; then
  security add-generic-password \
    -a "thetube" \
    -s "share-token-mac" \
    -w "$TOKEN" \
    -U 2>/dev/null || security add-generic-password \
    -a "thetube" \
    -s "share-token-mac" \
    -w "$TOKEN"
  security add-generic-password \
    -a "thetube" \
    -s "share-secret-mac" \
    -w "$SECRET" \
    -U 2>/dev/null || security add-generic-password \
    -a "thetube" \
    -s "share-secret-mac" \
    -w "$SECRET"
  echo "Stored in Keychain:"
  echo "  thetube/share-token-mac  (the JWT)"
  echo "  thetube/share-secret-mac (the secret)"
  echo ""
  echo "Mac script reads both from Keychain (Touch ID),"
  echo "computes SHA256(secret + timestamp), sends as X-Pass header."
else
  echo "=== Phone Setup ==="
  echo ""
  echo "1. Open Shortcuts on Mac → edit 'Save to Tube'"
  echo "2. Paste TOKEN into the SHARE_TOKEN text field"
  echo "3. Paste SECRET into the SHARE_SECRET text field"
  echo "4. Shortcut computes: SHA256(secret + timestamp) → X-Pass header"
  echo "5. Syncs to phone via iCloud"
fi

echo ""
echo "=== Lambda Verification ==="
echo ""
echo "1. Receive request with Authorization: Bearer <token> + X-Pass header + X-Timestamp header"
echo "2. Decode JWT payload (base64) → get secret, scope, exp"
echo "3. Check exp > now"
echo "4. Check scope allows this operation"
echo "5. Compute SHA256(secret + X-Timestamp)"
echo "6. Compare to X-Pass header"
echo "7. Check X-Timestamp is within ±30 seconds of now"
echo "8. All pass → process request"
echo ""
echo "Expires: $EXP_DATE"
