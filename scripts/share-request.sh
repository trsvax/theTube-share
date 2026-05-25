#!/usr/bin/env bash
# Send a share request (capture or publish) from Mac.
# Reads secret from Keychain (Touch ID), computes time-based hash.
# Same auth pattern as the phone Shortcut.
#
# Usage:
#   Capture: bash scripts/share-request.sh capture --type image --file IMG_1234.HEIC --date 2026-05-23 --caption "temple gate"
#   Publish: bash scripts/share-request.sh publish --type image --file IMG_1234.HEIC --date 2026-05-23 --path ~/Photos/edited.jpg
#
# Requires: openssl, security (macOS Keychain), curl
set -euo pipefail

ENDPOINT="${SHARE_ENDPOINT:-https://thetube.today/tube/share}"

ACTION="${1:-}"; shift || { echo "Usage: share-request.sh [capture|publish] ..."; exit 1; }

TYPE="" FILE="" DATE="" CAPTION="" FILEPATH=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --type)    TYPE="$2"; shift 2 ;;
    --file)    FILE="$2"; shift 2 ;;
    --date)    DATE="$2"; shift 2 ;;
    --caption) CAPTION="$2"; shift 2 ;;
    --path)    FILEPATH="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$TYPE" || -z "$FILE" || -z "$DATE" ]] && {
  echo "Required: --type --file --date"
  exit 1
}

if [[ "$ACTION" == "publish" && -z "$FILEPATH" ]]; then
  echo "Publish requires --path <file>"
  exit 1
fi

if [[ -n "$FILEPATH" && ! -f "$FILEPATH" ]]; then
  echo "File not found: $FILEPATH"
  exit 1
fi

# Get token and secret from Keychain (Touch ID prompt)
TOKEN=$(security find-generic-password -a "thetube" -s "share-token-mac" -w)
SECRET=$(security find-generic-password -a "thetube" -s "share-secret-mac" -w)

# Compute time-based hash
TIMESTAMP=$(date +%s)
PASS=$(echo -n "${SECRET}${TIMESTAMP}" | openssl dgst -sha256 -binary | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

# Build request
if [[ "$ACTION" == "capture" ]]; then
  URL="${ENDPOINT}/add?type=${TYPE}&file=$(printf '%s' "$FILE" | sed 's/ /%20/g')&date=${DATE}"
  [[ -n "$CAPTION" ]] && URL="${URL}&caption=$(printf '%s' "$CAPTION" | sed 's/ /+/g')"

  echo "Capture: $FILE"
  echo "POST $URL"

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X POST "$URL" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Pass: ${PASS}" \
    -H "X-Timestamp: ${TIMESTAMP}")

  if [[ -z "$HTTP_CODE" || "$HTTP_CODE" == "000" ]]; then
    echo "Status: no response (endpoint unreachable or timed out)"
  else
    echo "Status: $HTTP_CODE"
  fi

elif [[ "$ACTION" == "publish" ]]; then
  URL="${ENDPOINT}/upload"
  CONTENT_TYPE=$(file --mime-type -b "$FILEPATH")

  echo "Publish: $FILE ($CONTENT_TYPE)"
  echo "POST $URL"

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "$URL" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Pass: ${PASS}" \
    -H "X-Timestamp: ${TIMESTAMP}" \
    -H "X-Share-Meta: type=${TYPE}&file=${FILE}&date=${DATE}" \
    -H "Content-Type: ${CONTENT_TYPE}" \
    --data-binary "@${FILEPATH}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  echo "Status: $HTTP_CODE"
  [[ -n "$BODY" ]] && echo "Response: $BODY"
else
  echo "Unknown action: $ACTION (use capture or publish)"
  exit 1
fi
