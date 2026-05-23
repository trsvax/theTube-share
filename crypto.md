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

The JWT is **signed but not encrypted** (for now). Claims are base64-encoded, readable if intercepted. Future upgrade: JWE encryption so only Lambda can read the claims.

## Verification (what Lambda does)

1. Receive `Authorization: Bearer <token>`, `X-Pass`, `X-Timestamp`
2. Base64-decode the JWT payload → extract `secret`, `scope`, `exp`
3. Check `exp > now` (not expired)
4. Check `scope` allows this operation (capture vs publish)
5. Verify JWT HMAC: `HMAC-SHA256(header.payload, secret) === signature` (not tampered)
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
| Phone (Shortcut) | Medium | Secret in Shortcut, phone lock screen protects |
| Browser | Medium | Uses Cognito, future `hashme` service computes hash |
| Kid's device | Medium | Short expiry, capture-only scope, you control minting |

All use the same verification path in Lambda. The difference is where the secret is stored and how long the token lives.

## Scope controls

| Scope | Allowed operations |
|-------|-------------------|
| `capture` | addCapture only (log intent, no upload) |
| `publish` | addCapture + publish (upload files) |

## Device identification

The `sub` claim identifies the device: `mac`, `iphone-15`, `kid-emma-iphone`. Lambda logs it. You can revoke by blocklisting a `sub` value, or just let the token expire and don't re-mint.

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

## Future: JWE encryption

Currently the JWT claims (including the secret) are base64-encoded, not encrypted. If intercepted, they're readable. To fix:

- Lambda gets a key pair (private in Secrets Manager)
- Mint script encrypts the JWT with Lambda's public key (JWE)
- Only Lambda can decrypt and read the claims
- Protects: secret, device name, scope — all hidden in transit and logs

Tradeoff: Lambda needs a private key (Secrets Manager cold-start cost). Worth it when the claims contain sensitive data (location, names). Not needed for filenames and dates.
