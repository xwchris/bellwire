# Bellwire Cloud quick start

This path uses the official Bellwire API and an already installed official iOS
build. It does not require a Cloudflare, Supabase, or Apple Developer account.

## See the complete product loop

1. Open Bellwire, sign in with Apple, and allow notifications.
2. On the empty home screen, choose **Create demo project**.
3. Confirm that the Bellwire Demo project, live status card, and sample
   deployment Event appear.
4. Open the Event detail to inspect delivery state. Provider acceptance and
   visible device presentation are separate checks.

The demo is idempotent for an account. Running it again reuses the existing
demo project rather than creating duplicates.

## Connect an Agent

1. In Bellwire Settings, choose **Generate binding code**.
2. In a clone of this repository, exchange the single-use six-digit code:

   ```bash
   node skills/bellwire/scripts/bellwire.mjs bind \
     --code 123456 \
     --name "Codex on Mac" \
     --json
   ```

3. Save the returned `bw_agent_...` token in your password manager or local
   secret store, then expose it only to the current shell:

   ```bash
   export BELLWIRE_AGENT_TOKEN='bw_agent_REPLACE_ME'
   ```

4. Confirm the connection and create a real project:

   ```bash
   node skills/bellwire/scripts/bellwire.mjs list-projects
   node skills/bellwire/scripts/bellwire.mjs create-project \
     --name "My Agent" \
     --category automation \
     --json
   ```

The Agent token manages projects and configuration. Production integrations
should create and use the narrower project-scoped Ingest token. Continue with
the [examples](../examples/README.md) for typed Event setup and runtime calls.

## Self-hosted API

Set `BELLWIRE_API_URL` before running the same CLI commands:

```bash
export BELLWIRE_API_URL='https://your-worker.example.workers.dev'
```

The App itself must also be compiled against that Worker, Supabase project, and
your Apple signing identity. Follow the [self-hosting guide](self-hosting.md).
