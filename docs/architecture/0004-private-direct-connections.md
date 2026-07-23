# ADR-0004: Keep private card payloads on the user-to-device data path

Status: Accepted

## Context

Hosted Surfaces are convenient, but Bellwire Cloud receives and stores their
display-ready payloads. Revenue, internal operations, and customer-derived
metrics can be sensitive even after aggregation. A native iOS app also cannot
reliably accept an inbound connection while suspended, so removing every relay
would sacrifice notification reliability.

## Decision

- Bellwire Direct separates the control plane from the card data plane.
- The iOS installation creates independent P-256 agreement and signing keys.
  Private keys remain in the device-only Keychain.
- A binding may expose only the public keys to the connected Agent.
- The Agent registers the signing public key with the user's service.
- Bellwire relays a short-lived connection manifest encrypted with ephemeral
  P-256 ECDH, HKDF-SHA256, and AES-256-GCM. Bellwire never receives the
  manifest plaintext or user-service credentials.
- The App decrypts and stores the manifest locally, deletes the relay envelope,
  then fetches live Surfaces directly from the user's HTTPS service.
- Direct requests use a P-256 signature over the method, encoded path and
  query, timestamp, nonce, and body digest. User services reject stale
  timestamps and atomically consume nonces.
- Hosted Events remain available for reliable APNs delivery, but Direct-mode
  integrations send only generic non-sensitive notification text until the
  encrypted notification envelope protocol is available.

## Consequences

- Bellwire Cloud still observes account, device-key, envelope timing, and
  ciphertext-size metadata, but not private card content or endpoint details.
- User services must expose a public HTTPS read endpoint and maintain a
  revocable device-key registry plus replay-resistant nonce storage.
- Card refresh depends on the user's service availability. Cached cards may
  remain visible when a direct refresh fails.
- Multiple devices require one registered public key and encrypted manifest per
  device.
- Bellwire Direct is additive; existing hosted integrations remain compatible.
