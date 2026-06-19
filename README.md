# theTube-share

Share system for [theTube](https://thetube.today). Capture intent from any Apple app, publish assets later. ~260 lines of code total.

## What this is

A content creation platform built on the Mac/iOS ecosystem with AI-driven workflow:

```
iPhone (capture) → iCloud (sync) → Mac (edit) → AI (compose) → theTube (publish)
```

Every step uses a native Apple tool. The AI is the connective tissue — it reads logs, drafts blocks, helps you compose. The code is small because the platform does the work.

## The pieces

| Component                 | Lines       | What it does                                  |
| ------------------------- | ----------- | --------------------------------------------- |
| CF function               | ~10         | `/tube/*?*` → log and 202                     |
| Registration endpoint     | ~40         | Register device public key to S3              |
| `register-device.sh`      | ~50         | Generate key pair, register with server       |
| `share-request.sh`        | ~70         | Capture/publish from Mac (signs with P-256)   |
| iOS app                   | native      | Capture/publish with Secure Enclave signing   |
| `[share]:` block renderer | ~40         | Render captures in posts                      |
| Lambda (publish)          | ~50         | Verify signature + store to S3                |

## The flow

The default workflow is capture-first:

**Capture** — out in the world, hit share, tap "Save to Tube." The iOS app signs and POSTs metadata to `/tube/share/add?type=image&file=...`. CloudFront logs it, returns 202. No upload, no Lambda. The photo stays in iCloud.

**Query** — back at the Mac, ask the AI "what did I capture today?" It reads the CloudFront logs, shows you the list. You pick the ones that matter.

**Publish** — Touch ID, the script uploads the edited photo. Lambda stores it to S3. The `[share]:` block gets its `src:`.

**Compose** — the AI drafts `[share]:` blocks from your captures, helps you write around them.

But other workflows work too:

**Photo → Edit → Share** — you take a photo, edit it in Apple Photos right away, and share the finished version directly. No capture step, no "come back later." The publish script (or drag to `/shares/`) handles it in one motion. The `[share]:` block gets both metadata and `src:` at the same time.

**Link → Share** — you're reading something in Safari, hit share, "Save to Tube." The URL is the capture. No photo, no file. Just a breadcrumb: "this mattered."

**Note → Share** — a thought while walking. Share sheet, type a sentence, done. `type=note`, the caption is the content.

**Batch edit → Publish** — you come back from a trip with 50 captures. Edit the best 10 in Photos, drag them all to `/shares/`. The build matches them to their capture log entries by filename.

**Preview → PDF → Share** — annotate a document in Preview, export as PDF, share it. `type=pdf`, the file lands in `/shares/`. Same system, different media. Not just photos.

The system doesn't enforce a single workflow. It just provides the primitives: capture (log intent), publish (upload asset), and the `[share]:` block (connect them in a post). How you combine them is up to the moment.

## Auth model

Public key signatures. Each device generates a P-256 key pair — private key stays in the Secure Enclave (iOS) or Keychain (Mac), never leaves the device. Public key registered on the server once. See [crypto.md](./crypto.md) for the full design.

```
Device:  Sign(private_key, method + path + timestamp + body_hash) → X-Signature header
Lambda:  fetch public key from registry → verify signature
```

| Client | Key storage                    | Scope   |
| ------ | ------------------------------ | ------- |
| iOS    | Secure Enclave + Face ID       | publish |
| Mac    | Keychain + Touch ID            | publish |

No shared secrets. No tokens. No minting ceremony. Native app required.

## Transport

The `?` in the URL decides where data lands:

- `POST /tube/share/add?type=image&file=...` → CF logs URL; Lambda verifies signature, returns 202
- `POST /tube/share/upload` (no `?`) → Lambda verifies signature, saves body to S3
- Both at once — metadata in `?`, file in body

No signature → 403. All requests must be signed by a registered device.

Same convention as all `/tube/` endpoints. Comments, reactions, bookmarks — all use the same pattern.

## The `[share]:` block

```markdown
[share]:
type: image
file: IMG_1234.HEIC
captured: 2026-05-23
caption: temple gate at sunset
src: /shares/K1jaBcDeFgH.jpg
```

Placeholder until `src:` is populated. Real image once it lands. Same pattern as `[design]:`.

## Scripts

```bash
# Register a new device (Mac bootstraps first, then registers others)
bash scripts/register-device.sh --device iphone-15 --scope publish

# Capture from Mac
bash scripts/share-request.sh capture --type image --file IMG_1234.HEIC --date 2026-05-23

# Publish from Mac
bash scripts/share-request.sh publish --type image --file IMG_1234.HEIC --date 2026-05-23 --path ~/edited.jpg

# Revoke a device
bash scripts/revoke-device.sh --device kid-emma-iphone

# Test the auth chain locally
bash scripts/verify-local.sh
```

## Roadmap

1. Device registration endpoint. P-256 key generation in iOS app.
2. Mac publish script + Lambda signature verification.
3. iOS native app — capture + publish with Secure Enclave signing.
4. MCP server (read-only AWS + GitHub, Touch ID on startup). Query captures, trace errors, check infra.

## Related

- `trsvax/theTube` — platform spec, `[share]:` block renderer
- `trsvax/thetube-comments` — same pattern (schema-only plugin repo)
- [crypto.md](./crypto.md) — auth design details
- [scripts/shortcut-design.md](./scripts/shortcut-design.md) — iOS Shortcut action-by-action
- [notes.md](./notes.md) — session notes and design decisions
