# Bellwire

Bellwire turns live project state and typed events into native iPhone cards, a
private inbox, and APNs notifications. It includes a Cloudflare Worker API,
durable Supabase storage and authentication, a native SwiftUI app, and an
installable Agent skill for connecting other repositories.

The hosted API is available at
[`https://api.bellwire.app`](https://api.bellwire.app).
Product requirements and internal planning documents are intentionally kept
out of this public repository.

## What is implemented

- Supabase-backed projects, devices, schemas, notification surfaces, tokens,
  events, delivery attempts, and per-token rate limits.
- Mutable live Surfaces keyed by project and stable name, with native `stats`,
  `metrics`, `progress`, `segmented_progress`, `alert`, and `timer` renderers.
- Supabase JWT authentication for users and one-time six-digit binding codes
  for scoped Agent tokens.
- Typed event validation, sensitive-field protection, idempotent ingestion,
  project pause controls, and retry-aware delivery health.
- Cloudflare Queue dispatch and APNs HTTP/2 provider-token authentication.
- Native iOS 17 SwiftUI inbox with Sign in with Apple, Keychain session
  storage, APNs registration, deep links, device management, and light/dark
  appearance.
- A reusable skill in [`skills/bellwire`](skills/bellwire) with a
  dependency-free CLI and adapter references.

## Architecture

```text
Project / Agent
      │ live Surface update or typed Event
      ▼
Cloudflare Worker ──► Supabase (auth, config, inbox, delivery state)
      │
      └──► Cloudflare Queue ──► APNs ──► Bellwire iOS
```

Events remain durable if Queue submission is temporarily unavailable. For a
registered device, the API records `retryable:QueueUnavailable` as degraded
delivery health instead of returning a misleading storage failure.

## Local development

Requires Node.js 20 or newer.

```bash
npm install
cp .env.example .dev.vars
npm run dev
```

Run all local checks:

```bash
npm test
npm run lint
npm run typecheck
npm run build
npm run ios:build
```

The Worker uses in-memory storage only when `APP_ENV=development` and no
Supabase URL is configured. Staging and production fail closed unless both
Supabase settings are present.

## Cloud configuration

Non-secret Worker values live in [`wrangler.toml`](wrangler.toml). Configure
these encrypted secrets before APNs delivery:

```bash
wrangler secret put SUPABASE_SERVICE_ROLE_KEY
wrangler secret put APNS_KEY_ID
wrangler secret put APNS_TEAM_ID
wrangler secret put APNS_PRIVATE_KEY
```

`APNS_PRIVATE_KEY` is the complete `.p8` content. Use `sandbox` while running a
development-signed app and switch both the Worker environment and device build
to production together. Never commit service-role, Agent, Ingest, or APNs
private keys.

Verify an APNs key, Team ID, bundle topic, and environment without sending to a
real device. A successful credential check returns the expected
`BadDeviceToken` response for the synthetic token:

```bash
node scripts/verify-apns.mjs /secure/path/AuthKey_KEYID.p8 KEYID TEAMID app.bellwire sandbox
```

Apply database migrations from [`supabase/migrations`](supabase/migrations) to
the configured project. The hosted project already has native Apple auth
enabled for bundle ID `app.bellwire`; a web OAuth secret is not needed
for the app's native ID-token flow.

## iOS app

Open [`ios/Bellwire/Bellwire.xcodeproj`](ios/Bellwire/Bellwire.xcodeproj) in
Xcode. The project uses Team `98JU6VDJZU`, bundle ID
`app.bellwire`, Push Notifications, and Sign in with Apple.

An unsigned Simulator build is reproducible with `npm run ios:build`. A signed
device build additionally requires an Apple Developer account in Xcode, an App
ID/provisioning profile for the bundle ID, and the matching APNs key configured
on the Worker.

## API surface

All management routes require a Supabase user JWT or scoped Agent token.
Ingestion uses a project-scoped Ingest token.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Service health |
| `POST` | `/v1/device-bindings` | Create a one-time Agent binding code |
| `POST` | `/v1/device-bindings/confirm` | Exchange a code for an Agent token |
| `GET, POST` | `/v1/devices` | List or register iOS devices |
| `DELETE` | `/v1/devices/:deviceId` | Remove an owned device |
| `GET, POST` | `/v1/projects` | List or create projects |
| `GET, PATCH` | `/v1/projects/:projectId` | Inspect or pause a project |
| `POST` | `/v1/projects/:projectId/event-schemas` | Create a versioned Event Schema |
| `POST` | `/v1/projects/:projectId/notification-surfaces` | Create a notification Surface |
| `GET` | `/v1/surfaces` | List current live Surfaces across projects |
| `GET` | `/v1/projects/:projectId/surfaces` | List current project Surfaces |
| `PUT, DELETE` | `/v1/projects/:projectId/surfaces/:surfaceKey` | Update or end a stable live Surface |
| `POST` | `/v1/projects/:projectId/ingest-tokens` | Issue an Ingest token |
| `DELETE` | `/v1/projects/:projectId/ingest-tokens/:tokenId` | Revoke an Ingest token |
| `POST` | `/v1/events/:projectId` | Ingest an idempotent event |
| `POST` | `/v1/projects/:projectId/events/test` | Send an authenticated test event |
| `GET` | `/v1/inbox` | List the user's recent cross-project events |
| `GET` | `/v1/projects/:projectId/events` | List project events |
| `GET` | `/v1/events/:eventId` | Get event detail and sensitive-field metadata |
| `POST` | `/v1/events/:eventId/read` | Mark an event read |
| `GET` | `/v1/events/:eventId/deliveries` | Inspect APNs attempts |
| `GET` | `/v1/projects/:projectId/delivery-health` | Aggregate delivery health |

Schema fields support `string`, `number`, `boolean`, `datetime`, `url`, and
`enum`. Each field may set `required` and `sensitive`; enum fields require a
non-empty string `values` array. Sensitive fields may appear in authenticated
detail views but are rejected from notification templates.

Event ingestion requires `Authorization: Bearer <ingest-token>` and a stable
`Idempotency-Key` header:

```json
{
  "type": "payment.success",
  "data": {
    "orderId": "ord_123",
    "amount": 28,
    "currency": "CNY"
  },
  "occurredAt": "2026-07-20T09:30:00Z"
}
```

A new event returns `201`; replaying the same project and key returns `200`
with the original Event ID and `"deduplicated": true`.

## Live smoke test

[`scripts/live-smoke.mjs`](scripts/live-smoke.mjs) verifies real Supabase Auth,
the hosted Worker, project/schema/token creation, idempotent event ingestion,
inbox/detail reads, and Agent binding. It creates a temporary confirmed user
and deletes that user plus cascaded data in `finally`.

Pipe the Supabase secret key through stdin so it is neither persisted nor
printed:

```bash
pbpaste | npm run test:live
```
