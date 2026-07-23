# Bellwire integration examples

These examples send typed Events after the source operation has succeeded. They
use three runtime values that must stay outside Git:

- `BELLWIRE_INGEST_TOKEN`: the project-scoped `bw_live_...` token.
- `BELLWIRE_PROJECT_ID`: the destination project ID.
- `BELLWIRE_API_URL`: optional; defaults to `https://api.bellwire.app`.

## Configure an Event type

After binding the CLI with an Agent token, create a schema from one of the
templates:

```bash
node skills/bellwire/scripts/bellwire.mjs create-schema \
  --project "$BELLWIRE_PROJECT_ID" \
  --file examples/templates/deployment.failed.event-spec.json

node skills/bellwire/scripts/bellwire.mjs create-token \
  --project "$BELLWIRE_PROJECT_ID" \
  --name production \
  --json
```

Store the returned Ingest token in the source application's secret manager.
The token is shown only once.

## Choose an adapter

- [Node.js](node/send-event.mjs): dependency-free Node 22 script that reads a
  JSON Event file.
- [Shell](shell/send-event.sh): curl adapter suitable for deployment scripts.
- [Cloudflare Worker](cloudflare-worker/bellwire.ts): reusable function with a
  bounded timeout; store the token with `wrangler secret put`.
- [GitHub Actions](github-actions/deployment-failed.yml): failure notification
  using an Actions secret and repository variable.

Example Node invocation:

```bash
BELLWIRE_PROJECT_ID='project-id' \
BELLWIRE_INGEST_TOKEN='bw_live_REPLACE_ME' \
  node examples/node/send-event.mjs \
  examples/templates/deployment.failed.event.json \
  'deploy-run-123-failed'
```

Every retry of the same source operation and event kind must reuse the same
idempotency key. Do not substitute a random UUID for a durable business, task,
deployment, or workflow-run identifier.

## Scenario templates

- `payment.success`: records a completed payment without exposing the
  sensitive customer reference in the notification.
- `deployment.failed`: records the environment, revision, and safe diagnostic
  URL for a failed release.
- `agent.waiting`: records a task that needs a human decision.

Each scenario has an `.event-spec.json` file for configuration and a matching
synthetic `.event.json` payload for testing. Replace sample values before using
the payload in production, and never send credentials or unrestricted logs.
