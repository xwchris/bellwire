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
- Every project has exactly one data path: `private` or `hosted`.
- Private is the default. Bellwire accepts only an opaque, short-lived
  reference and relays a localized content-free APNs wake. The Notification
  Service Extension and App fetch detail directly from the user's service.
- Hosted is opt-in. An Agent can request it, but only the signed-in iOS user can
  approve Bellwire Cloud receiving and retaining Event, Inbox, Surface, and
  detailed notification content.
- Private and Hosted APIs and tokens are strictly isolated; a failed Private
  request never falls back to Hosted.

## Consequences

- Bellwire Cloud still observes account, device-key, envelope timing, and
  ciphertext-size metadata, but not private card content or endpoint details.
- User services must expose a public HTTPS read endpoint and maintain a
  revocable device-key registry plus replay-resistant nonce storage.
- Card refresh depends on the user's service availability. Cached cards may
  remain visible when a direct refresh fails.
- Local notification enrichment also depends on the user's service responding
  within the iOS extension execution window. The original generic alert is the
  deterministic fallback.
- Multiple devices require one registered public key and encrypted manifest per
  device.
- Direct v2 is the Private data-plane protocol. Version 1 and the former
  account-wide three-mode notification preference are intentionally unsupported.
