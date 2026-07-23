# Bellwire

Bellwire turns live project state and typed events into native iPhone cards, a
private inbox, and APNs notifications. It includes a Cloudflare Worker API,
durable Supabase storage and authentication, a native SwiftUI app, and an
installable Agent skill for connecting other repositories.

The hosted API is available at
[`https://api.bellwire.app`](https://api.bellwire.app).
Product requirements and internal planning documents are intentionally kept
out of this public repository.

> [!IMPORTANT]
> Bellwire is multi-licensed: the Worker and Supabase stack use AGPL-3.0-only,
> the iOS app uses MPL-2.0, and the Skill, CLI, protocol references, examples,
> and public docs use Apache-2.0. The Bellwire brand is reserved. See
> [LICENSE.md](LICENSE.md) for the exact path boundaries.

Start with the [five-minute hosted quick start](docs/quickstart.md), browse the
[integration examples](examples/README.md), or deploy the full stack with the
[self-hosting guide](docs/self-hosting.md).

## Choose a deployment

| | Bellwire Cloud | Self-hosted |
| --- | --- | --- |
| iOS build | Official signed build | Compile and sign your own fork |
| API and Queue | Operated by Bellwire | Your Cloudflare account |
| Auth and database | Operated by Bellwire | Your Supabase project |
| Push credentials | Bellwire App ID and APNs key | Your App ID and APNs key |
| Source code edits | None | None; use ignored local configuration |
| Operations | Managed service | You own upgrades, cost, security, and uptime |

Both paths use the same Event, Surface, Agent, and delivery contracts. Bellwire
Cloud is the convenience product; self-hosting is the control and auditability
path.

## Install the Agent Skill

Clone Bellwire and link the bundled Skill into Codex:

```bash
git clone https://github.com/xwchris/bellwire.git
mkdir -p "$HOME/.codex/skills"
ln -s "$(pwd)/bellwire/skills/bellwire" "$HOME/.codex/skills/bellwire"
```

Restart Codex, create a binding code in the iOS app, and ask Codex to use the
Bellwire Skill for the current repository. See the
[Skill installation guide](skills/bellwire/README.md) and
[hosted quick start](docs/quickstart.md) for the complete flow.

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
- Optional public HTTPS project logos in native project avatars and rich APNs
  notification attachments, with monogram fallback when an image is absent or fails.
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

Architecture decisions are recorded in [`docs/architecture`](docs/architecture).
Release history is recorded in [`CHANGELOG.md`](CHANGELOG.md).

## Local development

Requires Node.js 22 or newer.

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

Verify an APNs key locally without persisting or printing it. Add `-- --online`
to let APNs validate the provider token, bundle topic, and environment with a
synthetic device token that cannot receive a notification:

```bash
APNS_KEY_ID=ABC123DEFG \
APNS_TEAM_ID=ABC123DEFG \
APNS_BUNDLE_ID=app.bellwire \
APNS_ENVIRONMENT=sandbox \
  npm run self-host:apns-preflight < /secure/path/AuthKey_ABC123DEFG.p8
```

Apply database migrations from [`supabase/migrations`](supabase/migrations) to
the configured project. The hosted project already has native Apple auth
enabled for bundle ID `app.bellwire`; a web OAuth secret is not needed
for the app's native ID-token flow.

## iOS app

Open [`ios/Bellwire/Bellwire.xcodeproj`](ios/Bellwire/Bellwire.xcodeproj) in
Xcode. The project uses Team `98JU6VDJZU`, bundle ID
`app.bellwire`, Push Notifications, and Sign in with Apple.
Rich project-logo notifications also embed the
`app.bellwire.NotificationService` extension; its App ID and provisioning
profile must exist for signed device builds. iOS keeps the Bellwire app icon in
the collapsed notification and shows the project logo as a rich attachment.

An unsigned Simulator build is reproducible with `npm run ios:build`. A signed
device build additionally requires an Apple Developer account in Xcode, an App
ID/provisioning profile for the bundle ID, and the matching APNs key configured
on the Worker.

For a complete deployment using your own Apple, Supabase, and Cloudflare
accounts, follow the [self-hosting guide](docs/self-hosting.md). Self-hosted iOS
settings are supplied through an ignored `Local.xcconfig`; no Swift source edit
is required.

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
| `GET, PATCH, DELETE` | `/v1/projects/:projectId` | Inspect, update, or permanently delete a project |
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
| `POST` | `/v1/inbox/read-all` | Mark every unread owned event as read |
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

For self-hosted deployments, override `BELLWIRE_API_URL`, `SUPABASE_URL`, and
`SUPABASE_PUBLISHABLE_KEY`. The [self-hosting guide](docs/self-hosting.md) also
covers configuration diagnosis, APNs credential preflight, and the physical
device acceptance checklist.
