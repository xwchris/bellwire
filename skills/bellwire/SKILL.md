---
name: bellwire
description: Add, update, test, diagnose, or maintain Bellwire live cards and phone notifications in Node.js, Cloudflare Worker, and shell projects. Use when a user asks an agent to keep iPhone metrics, progress, alerts, timers, business stats, payments, deployments, jobs, or other project state visible; also use for Bellwire binding, live Surfaces, Event Specs, inbound provider webhooks, token rotation, test events, delivery checks, or notification troubleshooting.
---

# Bellwire

Connect repository state and events to the user's Bellwire cards, inbox, and iPhone while keeping authentication and notification details out of application code.

## Workflow

1. Inspect the repository, its secret-management convention, tests, and the exact successful or failed state that should trigger the event.
2. Clarify only product decisions that code cannot answer: notification frequency, sensitive values, and whether a high-priority interruption is justified.
3. Ensure `BELLWIRE_AGENT_TOKEN` is available outside tracked files. If it is missing, ask the user for the six-digit code shown in the iOS app and run:

   ```bash
   node <skill-dir>/scripts/bellwire.mjs bind --code 123456 --name "Codex on Mac"
   ```

   Store the returned Agent token in the user's approved secret store. Never commit it.
4. Create or reuse the Bellwire project. Search existing configuration before creating another project.
5. Choose the right primitive:
   - Use a live Surface for current state that should update in place, such as stats, health, progress, an alert, or a timer. Read [surfaces.md](references/surfaces.md).
   - Use an Event for durable history, completion, failure, recovery, or a decision boundary. Read [event-spec.md](references/event-spec.md).
6. For a Surface, choose a stable key and upsert the already-computed display state. Do not create a new key for every update.
7. For an Event, define minimal fields, create the schema and notification Surface, then create a project-scoped Ingest Token. Mark personal, credential, or customer identifiers `sensitive: true`.
8. Modify the smallest reliable trigger point. Send or update only after the underlying business operation commits.
   - Prefer a direct post-commit Bellwire call when the application owns the business operation.
   - When a payment, commerce, deployment, or automation provider is the source of truth, read [webhooks.md](references/webhooks.md) and add a provider-specific webhook adapter.
9. Run the repository's existing tests plus a focused test. Never weaken a business test to make Bellwire pass.
10. Persist and deploy the source-side adapter through the repository's real source of truth. If commit or push is outside the user's request, report that explicitly instead of calling the integration durable.
11. Verify the integration level using [production-verification.md](references/production-verification.md). Do not claim the phone presented a notification when the server only reports `accepted_by_apns`.

## Integration status

Use these exact boundaries in progress and final reports:

- **Configured:** the Bellwire project, schema, token, Surface, or test Event exists. This is not a production integration.
- **Integrated, awaiting production verification:** source-side adapter code, runtime secrets, focused tests, and deployment are present, but no real source operation has completed the path.
- **Production verified:** a real business operation created the expected Event or Surface, Delivery was checked, and any claimed device presentation was confirmed by the user.

Never describe `send-test`, a manually upserted Surface, or secret creation as an actual production integration.

## Commands

Use [scripts/bellwire.mjs](scripts/bellwire.mjs) for API operations. It defaults to the official hosted API and accepts `BELLWIRE_API_URL` for self-hosted installations.

```bash
node <skill-dir>/scripts/bellwire.mjs create-project --name "VideoSays" --logo-url "https://videosays.com/logo.png"
node <skill-dir>/scripts/bellwire.mjs update-project --project <id> --logo-url "https://cdn.example.com/logo.png"
node <skill-dir>/scripts/bellwire.mjs delete-project --project <id>
node <skill-dir>/scripts/bellwire.mjs create-schema --project <id> --file event-spec.json
node <skill-dir>/scripts/bellwire.mjs create-token --project <id> --name production
node <skill-dir>/scripts/bellwire.mjs upsert-surface --project <id> --key prod-api --file surface.json
node <skill-dir>/scripts/bellwire.mjs list-surfaces --project <id>
node <skill-dir>/scripts/bellwire.mjs send-test --project <id> --file test-event.json
node <skill-dir>/scripts/bellwire.mjs event --event <event-id>
node <skill-dir>/scripts/bellwire.mjs health --project <id>
```

`delete-project` is permanent and cascades through the project's schemas, tokens, events,
deliveries, and live Surfaces. Resolve the exact project ID and require explicit user intent
before running it.

Use `--json` for machine-readable output. Read [api.md](references/api.md) when adding another operation or diagnosing an error response.

## Adapter routing

- Read [adapters.md](references/adapters.md) for Node.js, Cloudflare Worker, Shell, and GitHub Actions patterns.
- Read [webhooks.md](references/webhooks.md) when receiving Stripe-like payment events or any third-party callback before updating Bellwire.
- Prefer the project's existing HTTP client. Do not add an SDK dependency for one request.
- Treat event sending as a bounded side effect: set a timeout, avoid logging payloads, and decide explicitly whether notification failure may affect the business operation. Default to best-effort after the business operation succeeds.
- Keep token values out of generated diffs, test snapshots, CI logs, and error telemetry.

## Event rules

- Use lowercase dotted names such as `payment.success`, `deployment.failed`, or `agent.waiting`.
- Include only fields needed for the inbox, notification, deep link, or diagnosis.
- Never reference a sensitive field in a notification template; the API rejects it.
- Use order IDs, deployment IDs, task IDs, or run IDs for idempotency. Do not use random UUIDs for real events.
- Avoid high-frequency progress events. Prefer completion, failure, recovery, and decision-required boundaries.
- Ask for explicit user approval before requesting `priority: high`.

## Surface rules

- Reuse a meaningful stable key such as `sales-today`, `prod-api`, or `nightly-backup`.
- Send display-ready values. For example, compute revenue in the source system and send `¥2,430`; Bellwire does not infer business aggregation from raw events.
- Choose one of the supported native types. Never embed HTML, JavaScript, Swift, CSS, or arbitrary rendering instructions.
- Prefer a Surface for frequent progress and metric updates; avoid flooding the Event inbox.
- Use `open_url` actions only when the destination is expected and safe for the user.
- Project logos must be public HTTPS images no larger than 5 MB. Bellwire uses
  them in native avatars and expanded rich notifications, then falls back to a
  project monogram if the image is missing or cannot be downloaded.

## Verification and recovery

If setup fails, read [troubleshooting.md](references/troubleshooting.md). Check in this order:

1. API reachability and management-token scope.
2. Project ID and active schema version.
3. Secret availability in the actual runtime.
4. Payload type and required fields.
5. Stable `Idempotency-Key` behavior.
6. Source adapter presence in the deployed version and a real source operation.
7. Event detail, Surface state, and Delivery status.
8. iOS notification permission, device registration, and sandbox versus production APNs environment.

Never rotate, revoke, or replace a working token unless the user requested it or compromise is suspected.
