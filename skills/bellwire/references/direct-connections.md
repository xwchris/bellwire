# Bellwire Direct

Use Bellwire Direct when card data should travel from the user's service to the
iPhone without Bellwire storing or reading the payload.

## Protocol

1. Bind with the six-digit code. A privacy-capable App returns `deviceKey` with:
   `id`, `agreementPublicKey`, `signingPublicKey`, `installationId`, and `algorithm`.
2. Register `deviceKey.id` and `deviceKey.signingPublicKey` in the user's service.
   Store one record per device and support explicit revocation.
3. Implement an HTTPS `GET` endpoint that returns the standard
   `{ "surfaces": [...] }` response. Keep the response below 1 MB.
   To support private Lock Screen details, also implement `notificationPath`.
   Bellwire appends an opaque `ref` query parameter and expects a response
   below 64 KB containing `title`, `body`, and optional `subtitle` and
   `logoUrl`.
4. Verify every request with
   [verify-direct-request.mjs](../scripts/verify-direct-request.mjs). Persist each
   nonce atomically with a unique constraint and reject timestamps outside five
   minutes. KV read-then-write is not sufficient for replay protection.
5. Create a version 1 manifest using
   `examples/templates/direct-connection.manifest.json`. Do not put passwords,
   bearer tokens, cookies, or provider secrets in the manifest.
6. Encrypt and publish the manifest:

   ```bash
   node <skill-dir>/scripts/bellwire.mjs publish-direct-connection \
     --device-key-id "$BELLWIRE_DEVICE_KEY_ID" \
     --agreement-public-key "$BELLWIRE_AGREEMENT_PUBLIC_KEY" \
     --file direct-connection.json
   ```

The CLI derives an AES-256-GCM key using ephemeral P-256 ECDH and HKDF-SHA256.
Bellwire stores only the ephemeral public key and sealed box for up to 24 hours.
The iPhone decrypts the manifest, stores it in the device-only Keychain, deletes
the envelope, and then contacts the user's HTTPS endpoint directly.

## Signed request

The App sends:

```http
X-Bellwire-Connection: <connectionId>
X-Bellwire-Key-Id: <deviceKey.id>
X-Bellwire-Timestamp: <unix seconds>
X-Bellwire-Nonce: <random value>
X-Bellwire-Signature: <base64 P-256 raw signature>
```

The signed UTF-8 value is:

```text
METHOD
PERCENT_ENCODED_PATH_AND_QUERY
UNIX_TIMESTAMP
NONCE
LOWERCASE_SHA256_BODY_HEX
```

Use HTTPS without embedded credentials. Return `401` for invalid keys,
signatures, timestamps, or reused nonces. Never fall back to an unsigned
response.

## Notification privacy modes

Read `GET /v1/events/:projectId/notification-preference` with the project Ingest
Token before sending private events. If the mode is `generic` or
`local_enrichment`, send only a generic Event with a stable, opaque
`directNotificationRef` field and store the matching detail on the user's
service. Mark that field sensitive in the Event Schema.

- `generic`: Bellwire and APNs receive only a generic alert. The extension does
  not fetch notification detail.
- `local_enrichment` (default): Bellwire and APNs receive the same generic
  alert and opaque reference. Before presentation, the iPhone signs a request
  to `notificationPath`, fetches the detail directly, and rewrites the Lock
  Screen notification. Failure falls back to the generic alert.
- `hosted_detailed`: send the existing detailed Event. Bellwire renders and
  relays the title and body through APNs.

If the preference request fails, default to `local_enrichment` and do not send
private values to Bellwire. Never include revenue, customer, order, credential,
or free-form content in a generic or local-enrichment Event.
