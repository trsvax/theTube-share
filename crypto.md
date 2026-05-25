# Share System — Auth & Crypto

How requests are authenticated. One model for all devices.

## The model

Every device (Mac, phone, kid's iPad) gets a **minted JWT** with an embedded **shared secret**. At request time, the device computes a time-based hash to prove it has the secret right now.

```
Token (JWT):     carries identity, scope, and the secret itself
Secret:          stored separately on the device (Keychain / Shortcut)
X-Pass header:   SHA256(secret + unix_timestamp) — proves liveness
X-Timestamp:     the timestamp used in the hash — checked for ±30s drift
```

## Minting

Done on your Mac with `mint-token.sh`. Touch ID to authorize.

```bash
mint-token.sh --device mac --scope publish --days 365
mint-token.sh --device iphone --scope capture --days 90
mint-token.sh --device kid-emma --scope capture --days 30
```

The script generates a random secret, embeds it in the JWT payload, signs the JWT with HMAC-SHA256 (using the secret as the key), and stores both in Keychain (Mac) or prints them for the Shortcut (phone).

## JWT structure

```json
{
  "alg": "HS256",
  "typ": "JWT"
}
{
  "iss": "share-mac",
  "sub": "mac",
  "scope": "publish",
  "secret": "ybVkb0ee8lQKswRvmMe5iwgmrsTIfJiGat_Y_jF9buc",
  "iat": 1716480000,
  "exp": 1748016000
}
```

The JWT is **encrypted (JWE)** — claims are only readable by Lambda. The token is an opaque blob to anyone who intercepts it. See the JWE encryption section below for details.

## Verification (what Lambda does)

1. Receive `Authorization: Bearer <encrypted-token>`, `X-Pass`, `X-Timestamp`
2. Decrypt JWE with Lambda's private key → get claims
3. Extract `secret`, `scope`, `exp`
4. Check `exp > now` (not expired)
5. Check `scope` allows this operation (capture vs publish)
6. Compute `SHA256(secret + X-Timestamp)`, compare to `X-Pass` (client has the secret)
7. Check `X-Timestamp` within ±30 seconds of now (not a replay)

All pass → process the request.

## What each check proves

| Check | Proves |
|-------|--------|
| exp | Token hasn't expired |
| scope | Token is authorized for this operation |
| HMAC | Token hasn't been modified since minting |
| X-Pass hash | Client has the secret right now |
| ±30s window | Request is fresh, not replayed |

## What an attacker needs

- Token alone → fails (can't compute hash without secret)
- Secret alone → fails (no valid token to present)
- Both, but later → fails (timestamp outside window)
- Both, right now → succeeds, but requires the unlocked device

## Where things live

| Thing | Mac | Phone | Lambda |
|-------|-----|-------|--------|
| JWT token | Keychain (`share-token-mac`) | Shortcut text field | Receives in header |
| Secret | Keychain (`share-secret-mac`) | Shortcut text field | Extracts from JWT |
| Hash computation | `openssl dgst` | Shortcuts "Generate Hash" | `SHA256()` to verify |

## Trust levels

| Client | Trust | Why |
|--------|-------|-----|
| Mac | High | Keychain + Touch ID, secret never on disk |
| Phone (Shortcut) | Medium | Secret in Shortcut text field, iCloud-synced — known risk. Fix is a native app with Secure Enclave. Not worth the work for personal capture. |
| Browser | Medium | Uses Cognito, future `hashme` service computes hash |
| Kid's device | Medium | Short expiry, capture-only scope, you control minting |

All use the same verification path in Lambda. The difference is where the secret is stored and how long the token lives.

## Scope controls

| Scope | Allowed operations |
|-------|-------------------|
| `capture` | addCapture only (log intent, no upload) |
| `publish` | addCapture + publish (upload files) |

## Device identification

The `sub` claim identifies the device: `mac`, `iphone-15`, `kid-emma-iphone`. Lambda logs it.

## Revocation

No server-side revocation. Tokens are valid until `exp`. The model is:

- **Mac** — your device, your Keychain. No revocation needed.
- **Kids** — short expiry (30 days), capture-only scope. Revoke = don't re-mint when it expires. If a token leaks before expiry, wait it out — 30 days, capture-only, personal site. Acceptable.

There are no public users with minted tokens. A real multi-user system uses Cognito — group membership, token revocation, refresh flows, all built in. Minted JWTs are personal tooling, not a user auth system.

## Multi-user (future)

| User type | Auth |
|-----------|------|
| You (devices) | Minted JWT + secret (this system) |
| Other users (web) | Cognito JWT + groups |

Both paths converge at the same Lambda. Check `iss` to decide which verification to use.

## Key loss scenarios

| Lost | Impact | Recovery |
|------|--------|----------|
| Mac secret (Keychain wiped) | Can't publish from Mac | Re-mint a new token |
| Phone token | Can't capture from phone | Re-mint, paste into Shortcut |
| All tokens | No devices can auth | Re-mint everything on Mac |

No server-side state is lost. The tokens are the auth system. Mint new ones anytime.

## JWE encryption

The JWT must be encrypted (JWE), not just signed. The secret is in the claims — if the token is readable, the secret is exposed and the time-hash can be forged. JWE ensures only Lambda can read the claims.

**How it works:**

- Lambda has a key pair (private key in Secrets Manager, encrypted backup in `infra/secrets/`)
- Lambda's public key lives in the share repo (`keys/share-encrypt-public.pem`)
- `mint-token.sh` encrypts the JWT with Lambda's public key
- The token is opaque — base64 blob, claims unreadable without the private key
- Lambda decrypts at request time, extracts the secret, verifies the time-hash

**What's protected:**

- The embedded secret (can't forge hashes without it)
- Device name, scope, role (can't see what the token allows)
- Expiry (can't tell when it dies)

**Key loss:**

- Lose Lambda's private key → can't decrypt any existing tokens. But: the capture index (in CF logs, in the URL) survives. Only the private metadata is lost. Re-mint all tokens, redeploy with new key pair.

**Where the keys live:**

```
theTube-share/keys/share-encrypt-public.pem   ← Mac uses this to encrypt
thetube-private/infra/secrets/share-decrypt.enc ← Lambda's private key (encrypted with vault key)
Secrets Manager: thetube/share-decrypt-key     ← Lambda reads at cold start
```

**Verification with JWE:**

1. Receive `Authorization: Bearer <encrypted-token>`, `X-Pass`, `X-Timestamp`
2. Decrypt JWE with Lambda's private key → get claims
3. Extract `secret`, `scope`, `exp`, `sub`
4. Check `exp > now`
5. Check `scope` allows this operation
6. Compute `SHA256(secret + X-Timestamp)`, compare to `X-Pass`
7. Check `X-Timestamp` within ±30s
8. All pass → process request

Same verification chain as before. The only difference: step 2 is decrypt instead of base64-decode.
