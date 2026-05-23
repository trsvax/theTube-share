# Notes

Design decisions and session notes.

## 2026-05-23 — Initial design session

### Started with key pairs, ended with shared secrets

The original plan was asymmetric crypto: private key on Mac (openssl + Touch ID), public key in the repo, Lambda verifies signatures. Two different auth paths — key pair for Mac, bearer token for phone.

Realized: the Mac and phone have basically the same trust level. If someone has either device unlocked, you've got bigger problems. Unified to one model: minted JWTs with embedded secrets and time-based hashes. Same verification path for all devices.

### The JWT carries its own state

The secret is embedded in the JWT payload. Lambda doesn't store secrets — it extracts them from the token at request time. No database of secrets, no session store. The token is the auth system.

### Time-based hash prevents replay

The phone can hash (Shortcuts has a native SHA256 action). So: `SHA256(secret + unix_timestamp)` in the `X-Pass` header. Lambda computes the same hash, compares. Valid for ±30 seconds. Can't replay old requests.

### Encrypted vs signed JWTs

Signed (JWS): anyone can read the claims, nobody can forge them. Good for: filenames, dates, device names in logs.

Encrypted (JWE): only Lambda can read the claims. Good for: location, people's names, private notes. Requires Lambda to have a private key (Secrets Manager).

Decision: signed for now. The claims are just metadata (filenames, dates). Encryption is a future upgrade for when claims contain sensitive data (location).

### Two trust tiers remain

- `?` present → batch, log only, 202, no compute
- No `?` → Lambda processes, compute

But the auth is unified. Both use the same minted JWT + time-hash. The `scope` claim in the JWT controls what's allowed (capture vs publish).

### Multi-user

- Family: mint tokens on Mac, hand them out. `role` and `scope` in the JWT.
- Public: Cognito. Lambda checks `iss` to decide verification path.
- Both coexist. Same endpoint, different auth mechanisms.

### Passkeys for browser writes

Identity (JWT) is always present — the site knows who you are. Writes require escalation: passkey (Touch ID in browser), time-hash (devices), or Cognito + group (web users).

### The `/w/` path is generic

Not specific to share. Comments, reactions, bookmarks — all use the same pattern. Build the CF function once, every write operation uses it.

### MCP closes the loop

Capture in the field → query later with AI → compose the post. The MCP server reads CloudFront logs, shows you what you captured. No CLI, no CloudWatch console.

### AWS as a filesystem

The `/proc` idea: Lambda serves AWS state as a WebDAV filesystem. Mount it on your Mac. `ls /proc/lambda/` lists functions. `cat /proc/cf/.../behaviors` shows CloudFront config. Future work, but the architecture is clear.

### S3 WebDAV for publish

Mount S3 as a folder. Drag photos to `/shares/`. No Lambda in the publish path for the Mac. The Mac writes directly. Existing tools (SFTPGo, aws-s3-webdav) solve this already.

### SQLite for state

`state.db` in the private repo. Tracks captures, tokens, deploys. Git versions it. MCP queries it. No DynamoDB, no running service.

### What got built

- `schema.graphql` — operations and types
- `crypto.md` — full auth design
- `scripts/mint-token.sh` — mint tokens for any device
- `scripts/share-request.sh` — capture/publish from Mac
- `scripts/verify-local.sh` — test auth chain locally (passing ✓)
- `scripts/shortcut-design.md` — iOS Shortcut reference
- `README.md` — content creation platform overview
- `theTube-mcp/` — MCP server scaffold (separate repo)

### What's next

1. CF function for `/w/*?*` → 202
2. Connect MCP server, verify logs
3. iOS Shortcut (build on Mac, syncs to phone)
4. `[share]:` block renderer in the site
5. Virtual WebDAV — mount the content as a filesystem, organized by post type. Read-only from local repos first. When you need remote data (logs, S3, pending captures), build the edge functions to serve it. The filesystem drives the MCP design — the questions you ask while browsing are the tools the AI needs.
