# AGENTS.md

Guidance for automated agents working in this repository.

## Don't make assumptions. If you don't know something, say so.

---

## Project Overview

`theTube-share` is a share system spec for the theTube platform. It contains no code — only a GraphQL schema describing share operations and their behavior.

This repo is a plugin. AI reads the schema here and the platform spec at `trsvax/theTube` to generate an implementation native to the target site.

---

## Architecture

```
schema.graphql    The share operations, types, and directives
README.md         How to use this spec
AGENTS.md         This file
```

## How it works

1. The schema defines operations: `addCapture` (field capture), `publish` (upload)
2. Directives declare behavior: `@moderate` (batch/log), `@realtime` (compute), `@auth` (trust tier)
3. The platform spec (in `trsvax/theTube`) defines how directives map to transport
4. AI combines both to generate implementation code for the target site

## Auth model

Public key signatures. Each device generates a P-256 key pair — private key in Secure Enclave (iOS) or Keychain (Mac), public key registered on server. No shared secrets, no tokens, no JWTs.

| Operation    | Auth                                        | Transport                                                   |
| ------------ | ------------------------------------------- | ----------------------------------------------------------- |
| `addCapture` | P-256 signature (registered device)         | `?` present → CF logs URL → Lambda verifies sig → 202       |
| `publish`    | P-256 signature (device with publish scope) | No `?` → Lambda verifies sig + saves body to S3             |

## The `?` convention

Driven by how AWS logging works: CloudFront logs the URL (path + query string), not the body.

Every request must be signed by a registered device (`X-Device-Id`, `X-Timestamp`, `X-Signature`). No signature → 403. Device scope is stored server-side.

- Query string present (`?`) = data is also in the URL. CloudFront logs it automatically. Lambda verifies signature, reads data from the logged URL, acts.
- No query string = data is only in the body. Lambda verifies signature, reads body, saves to S3.
- Both can coexist — `?` for metadata CF logs, body for the file.

## No code here

This repo never contains implementation code. It's a spec. The implementation is generated fresh for each site that uses it, native to that site's platform, design, and stack.

## Related

- `trsvax/theTube` — platform spec, `[share]:` block renderer in `lib/posts.ts`
- `trsvax/thetube-comments` — same pattern (schema-only plugin repo)

_Last updated: 2026-06-19_
