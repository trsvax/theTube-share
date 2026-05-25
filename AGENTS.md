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

## The two trust tiers

| Operation    | Trust                         | Auth                                       | Transport                           |
| ------------ | ----------------------------- | ------------------------------------------ | ----------------------------------- |
| `addCapture` | USER — any authenticated user | Long-lived JWT in Keychain                 | `?` present → CloudFront logs → 202 |
| `publish`    | OWNER — signature-verified    | openssl-signed payload, public key in repo | No `?` → Lambda processes body      |

## The `?` convention

Driven by how AWS logging works: CloudFront logs the URL (path + query string), not the body.

Trust model: JWT present → Lambda spins up to verify it and decide what to do. No JWT → endpoint doesn't exist (404). The `?` is data format only, not a routing signal.

- Query string present (`?`) = data is also in the URL. CloudFront logs it automatically. Lambda verifies JWT, reads data from the logged URL, acts.
- No query string = data is only in the body. Lambda verifies JWT, reads body, saves to S3.
- Both can coexist — `?` for metadata CF logs, body for the file.

## No code here

This repo never contains implementation code. It's a spec. The implementation is generated fresh for each site that uses it, native to that site's platform, design, and stack.

## Related

- `trsvax/theTube` — platform spec, `[share]:` block renderer in `lib/posts.ts`
- `trsvax/thetube-comments` — same pattern (schema-only plugin repo)

_Last updated: 2026-05-23_
