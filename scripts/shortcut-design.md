# Save to Tube — iOS Shortcut Design

Receives a share from any app (Photos, Safari, Notes), extracts metadata,
POSTs to /tube/share/add with a minted token + time-based hash.

## Auth Model

Token minted on Mac (`mint-token.sh`), stored in Shortcut.
Secret also stored in Shortcut. Shortcut computes SHA256(secret + timestamp)
at request time — proves it has the secret NOW, prevents replay.

## Shortcut Actions

```
┌─────────────────────────────────────────────────┐
│ Receive [Images, URLs, Text] from Share Sheet   │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Text: SHARE_TOKEN                               │
│ (pasted from mint-token.sh output)              │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Text: SHARE_SECRET                              │
│ (pasted from mint-token.sh output)              │
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
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Date: Current Date → format ISO 8601 → DATE     │
│ Date: Current Date → format Unix Epoch → TS     │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Ask for Input (optional): "Caption?"            │
│ → CAPTION (or empty)                            │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Generate Hash:                                  │
│   Input: [SHARE_SECRET][TS]                     │
│   Type: SHA256                                  │
│ → PASS                                          │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ URL Encode: FILE, CAPTION                       │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Text:                                           │
│ https://thetube.today/tube/share/add            │
│   ?type=[TYPE]                                  │
│   &file=[FILE]                                  │
│   &date=[DATE]                                  │
│   &caption=[CAPTION]                            │
│ → URL                                           │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ Get Contents of URL:                            │
│   Method: POST                                  │
│   Headers:                                      │
│     Authorization: Bearer [SHARE_TOKEN]         │
│     X-Pass: [PASS]                              │
│     X-Timestamp: [TS]                           │
│   (no body — data is in the URL)                │
└─────────────────────────────────────────────────┘
                      │
┌─────────────────────────────────────────────────┐
│ If result is not 202:                           │
│   Show Alert: "Share failed: [status]"          │
│ Else:                                           │
│   Show Notification: "Saved: [FILE]"            │
└─────────────────────────────────────────────────┘
```

## Token Refresh

When the token expires (default 90 days for phone):
1. On Mac: `bash scripts/mint-token.sh --device iphone --scope capture --days 90`
2. Edit the Shortcut on Mac, paste new token + secret
3. Syncs to phone automatically via iCloud

## Multi-device / Multi-user

Each device/person gets their own token minted on your Mac:
- `--device kid-emma-iphone --scope capture --days 30`
- `--device ipad-kitchen --scope capture --days 90`

Revoke = don't re-mint. Or add `sub` to a blocklist in Lambda.

## Notes

- No login flow on phone — token is pre-minted
- SHA256 hash is native in Shortcuts ("Generate Hash" action)
- Hash changes every second — can't replay a captured request
- Caption prompt is optional — tap "Skip" for quick captures
- No photo upload — the image stays in iCloud Photos
- The query string IS the data — CloudFront logs it and returns 202
- Works from any app's share sheet: Photos, Safari, Notes, Maps
