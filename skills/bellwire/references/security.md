# Security

- Store `BELLWIRE_AGENT_TOKEN` and `BELLWIRE_INGEST_TOKEN` only in platform secrets, an ignored local environment file, or the user's approved password manager.
- Store each provider webhook signing secret separately from Bellwire tokens. Never reuse one provider's signing secret for another endpoint or environment.
- Never add tokens to source, examples, fixtures, shell history, screenshots, issue text, or logs.
- Give each project its own Ingest Token. Do not reuse an Ingest Token across repositories.
- Treat email, phone, name, IP address, customer ID, access token, and free-form user content as sensitive unless the user says otherwise.
- Prefer Bellwire Direct for private metrics. Bellwire must receive only an encrypted connection envelope; the App pulls the card from the user's service with a signed device request.
- Persist Direct request nonces atomically. Do not use an eventually consistent read-then-write cache as the replay defense.
- Notification templates must not reference sensitive fields. The iOS app masks them in event detail by default.
- Use management tokens only for Bellwire configuration and tests. Application runtime code must use the narrower Ingest Token.
- Verify webhook signatures against the unmodified request body before parsing JSON. Use the provider's official verifier when one already exists.
- Rotate a token after accidental disclosure; update the runtime secret before revoking the old token to avoid event loss.
- Do not let a notification failure roll back a successful payment, deployment, or completed task unless the repository already defines that behavior.
