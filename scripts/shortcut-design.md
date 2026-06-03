# Save to Tube — iOS Shortcut Design

Fire-and-forget. Data in the URL. Edge returns 202. No ticket, no polling, no upload.

The phone captures intent — "I saw this, remember it." The photo stays on the device.
The processor reads the log later and reconciles.

## Auth Model

Token minted on Mac (`mint-token.sh --device iphone --scope capture`).
Token stored as a text field in the Shortcut (iCloud-synced).
Secret stored as a separate text field.

At request time: `SHA256(secret + timestamp)` proves the device has the secret now.

For fire-and-forget, auth travels in the query string as `auth=`:

```
POST /tube/share/add?auth=eyJ...&type=image&file=IMG_1234.HEIC&date=2026-06-02&caption=temple+gate
```

The edge sees `auth=` → passes through → 202 Noted. CloudFront logs the full URL. Done.

No `Authorization` header needed. No `X-Pass`. No `X-Timestamp`. The encrypted JWT in `auth=`
is enough for the fire-and-forget path — the processor verifies it later when reading logs.

## Why `auth=` instead of headers

1. CloudFront Functions can't read arbitrary headers in the viewer-request event reliably across all edge locations.
2. The edge only checks *presence* — it doesn't validate the token (can't do crypto).
3. The processor reads CloudFront logs. Logs include the query string. Logs do NOT include headers.
4. One URL = complete record. Auth, intent, and data in one logged line.

## Shortcut Actions

```
┌─────────────────────────────────────────────────┐
│ Receive [Images, URLs, Text] from Share Sheet   │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Text: SHARE_TOKEN                               │
│ (encrypted JWT from mint-token.sh)              │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ If input is Image:                              │
│   Get name of [Shortcut Input] → FILE           │
│   Set TYPE = "image"                            │
│ Else if input is URL:                           │
│   Set FILE = [Shortcut Input]                   │
│   Set TYPE = "link"                             │
│ Else:                                           │
│   Set FILE = "note"                             │
│   Set TYPE = "note"                             │
│   Set CAPTION = [Shortcut Input]                │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Date: Current Date → format "yyyy-MM-dd" → DATE │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Ask for Input (optional): "Caption?"            │
│ → CAPTION (or empty — tap Done to skip)         │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ URL Encode: FILE, CAPTION                       │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Text:                                           │
│ https://thetube.today/tube/share/add            │
│   ?auth=[SHARE_TOKEN]                           │
│   &type=[TYPE]                                  │
│   &file=[FILE]                                  │
│   &date=[DATE]                                  │
│   &caption=[CAPTION]                            │
│ → URL                                           │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Get Contents of URL:                            │
│   Method: POST                                  │
│   (no headers, no body — everything is in URL)  │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ If result is not 202:                           │
│   Show Alert: "Share failed"                    │
│ Else:                                           │
│   Show Notification: "✓ [FILE]"                 │
└─────────────────────────────────────────────────┘
```

## What the phone sees

Success: a notification "✓ IMG_1234.HEIC" — takes ~200ms (edge is sub-millisecond, network is the bottleneck).

Failure: an alert "Share failed" — means the token expired or the network is down. Re-mint.

## Token in the URL — is that safe?

The token is JWE-encrypted. It's an opaque base64url blob. Even if someone reads the URL from a log,
they can't extract the secret or forge a time-hash. Only Lambda (with the private key) can decrypt it.

For fire-and-forget, the token doesn't even need the time-hash — verification happens later
when the processor reads the log. The token's mere presence gets past the edge gate.
The processor validates everything (decrypt, expiry, scope) when it processes the batch.

## Token Refresh

When the token expires (default 90 days for phone):

1. On Mac: `bash scripts/mint-token.sh --device iphone --scope capture --days 90`
2. Edit the Shortcut on Mac (Shortcuts app), paste new token
3. Syncs to phone automatically via iCloud

## Multi-device / Multi-user

Each device gets its own token:

```bash
mint-token.sh --device iphone-15 --scope capture --days 90
mint-token.sh --device kid-emma-iphone --scope capture --days 30
mint-token.sh --device ipad-kitchen --scope capture --days 90
```

Revoke = don't re-mint when it expires.

## What the Shortcut does NOT do

- Upload files (photos stay in iCloud Photos — reconcile later from Mac)
- Poll for results (fire-and-forget, no waiting)
- Compute time-hashes (not needed for the URL path — processor verifies later)
- Read responses (beyond 202 vs not-202)

The phone is a capture device. The Mac is the publishing device. Different trust, different capability.
