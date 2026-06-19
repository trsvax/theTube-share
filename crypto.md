# Share System — Auth & Crypto

How requests are authenticated. Public key signatures, device keys in the Secure Enclave.

## The model

Every device generates a **key pair** at registration time. The private key lives in the Secure Enclave (iOS) or Keychain (Mac) — it never leaves the device. The public key is registered with the server once.

At request time, the device **signs** the request payload with its private key. Lambda verifies the signature against the registered public key.

```
Private key:     Secure Enclave (iOS) / Keychain (Mac) — never exported
Public key:      Registered on server at /tube/devices/{device-id}/key.pem
Signature:       Sign(private_key, method + path + timestamp + body_hash)
X-Signature:     base64-encoded signature
X-Timestamp:     unix seconds — checked for ±30s drift
X-Device-Id:     which device's public key to verify against
```

## Registration

Done once per device. The device generates a P-256 key pair, sends the public key to the server (authenticated by an existing device or a one-time setup token).

```
POST /tube/devices/register
X-Signature: <signed by existing device or setup token>
Body: { "deviceId": "iphone-15", "publicKey": "<PEM>", "scope": "publish" }
```

First device (Mac) is bootstrapped with a one-time setup token stored in Secrets Manager. After that, the Mac can register other devices.

## Key generation (iOS)

```swift
let privateKey = SecureEnclave.P256.Signing.PrivateKey()
let publicKey = privateKey.publicKey
// Export publicKey.pemRepresentation → register with server
```

## Key generation (Mac)

```swift
let privateKey = P256.Signing.PrivateKey()
// Store in Keychain with kSecAttrAccessControl (Touch ID required)
let publicKey = privateKey.publicKey
```

## Signing a request

The device signs a canonical string:

```
{method}\n{path}\n{timestamp}\n{body_sha256}
```

Example:
```
POST\n/tube/share/add\n1716480000\nSHA256(body)
```

For query-string captures (no body), `body_sha256` is the SHA256 of the empty string.

## Verification (what Lambda does)

1. Receive `X-Device-Id`, `X-Signature`, `X-Timestamp`
2. Look up device's public key from `/devices/{device-id}/key.json`
3. Check device is not revoked, check scope allows this operation
4. Reconstruct the canonical string from the request
5. Verify signature against public key (P-256 / ECDSA)
6. Check `X-Timestamp` within ±30 seconds of now

All pass → process the request.

## What each check proves

| Check       | Proves                                          |
| ----------- | ----------------------------------------------- |
| signature   | Request was signed by the device's private key  |
| ±30s window | Request is fresh, not replayed                  |
| scope       | Device is authorized for this operation         |
| body hash   | Body hasn't been tampered with in transit       |
| device-id   | Which key to verify — audit trail per device    |

## What an attacker needs

- Intercepted request → fails (can't forge new signatures without private key)
- Stolen public key → useless (can't sign, only verify)
- Stolen device → protected by Secure Enclave + Face ID / Touch ID
- Replay → fails (timestamp outside ±30s window)

## Where things live

| Thing       | iOS                          | Mac                          | Lambda                              |
| ----------- | ---------------------------- | ---------------------------- | ----------------------------------- |
| Private key | Secure Enclave               | Keychain (Touch ID)          | N/A                                 |
| Public key  | Enclave (derived)            | Keychain (derived)           | S3: /devices/{id}/key.json          |
| Signing     | `SecureEnclave.P256.Signing` | `P256.Signing.PrivateKey`    | N/A                                 |
| Verifying   | N/A                          | N/A                          | `crypto.createVerify` / P-256       |

## Trust levels

| Client | Trust  | Why                                                        |
| ------ | ------ | ---------------------------------------------------------- |
| iOS    | High   | Secure Enclave — private key can't be extracted, Face ID   |
| Mac    | High   | Keychain + Touch ID, key never leaves the process          |

No medium-trust tier. If the device can't do Secure Enclave or Keychain-protected keys, it doesn't get access. No more secrets in Shortcut text fields.

## Scope controls

| Scope     | Allowed operations                      |
| --------- | --------------------------------------- |
| `capture` | addCapture only (log intent, no upload) |
| `publish` | addCapture + publish (upload files)     |

Scope is stored server-side with the registered public key. The device doesn't declare its own scope.

## Device identification

`X-Device-Id` identifies the device: `mac`, `iphone-15`. Lambda logs it. Each device has its own key pair — revoke one without affecting others.

## Revocation

Server-side. Delete or mark the device's key record as revoked. Takes effect immediately — next request fails verification at step 3.

```
POST /tube/devices/revoke
X-Device-Id: kid-emma-iphone
X-Signature: <signed by owner device>
```

No expiry to manage. No re-minting. Revoke = delete the public key from S3.

## Key loss scenarios

| Lost                  | Impact                     | Recovery                              |
| --------------------- | -------------------------- | ------------------------------------- |
| iOS device            | That device can't auth     | Revoke its key, register the new one  |
| Mac (Keychain wiped)  | Can't publish from Mac     | Generate new key pair, re-register    |
| All devices           | No devices can auth        | Bootstrap with setup token again      |

No server-side state is lost. Public keys are just files in S3. Device generates a new pair, registers again.

## Why this is simpler

The old model: JWE-encrypted JWT, embedded shared secret, time-hash, `mint-token.sh`, Lambda decrypts to extract secret, HMAC verification.

The new model: device signs request, server verifies signature. No shared secrets. No encrypted tokens. No minting ceremony. The Secure Enclave does the hard part.

| Old                                | New                                    |
| ---------------------------------- | -------------------------------------- |
| Shared secret in JWT               | Private key in Secure Enclave          |
| JWE encryption                     | Not needed (no secret to hide)         |
| `mint-token.sh` on Mac             | One-time registration                  |
| `X-Pass` = SHA256(secret + time)   | `X-Signature` = Sign(canonical_string) |
| Lambda decrypts JWE to get secret  | Lambda fetches public key from S3      |
| Token expiry                       | Revocation (immediate)                 |
| Re-mint on expiry                  | Nothing — keys don't expire            |
| Secret in Shortcut (phone)         | Not possible — native app required     |

## The protocol

```
POST /tube/{path}
X-Device-Id: iphone-15
X-Timestamp: 1716480000
X-Signature: base64(sign(private_key, "POST\n/tube/share/add\n1716480000\n{body_sha256}"))
Content-Type: application/json
Body: {...}
```

200 = sync result. 202 = async (poll). 403 = auth failed.

## Device registry

```
s3://bucket/devices/
  mac/key.json           { "publicKey": "...", "scope": "publish", "registered": "..." }
  iphone-15/key.json     { "publicKey": "...", "scope": "publish", "registered": "..." }
```

Just files at URLs. `ls` the directory to see all devices. Delete a file to revoke.
