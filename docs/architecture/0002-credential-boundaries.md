# ADR-0002: Separate user, Agent, and Ingest credentials

Status: Accepted

## Context

iOS users, coding Agents, and production event sources have different trust and
revocation requirements. A single long-lived token would grant more authority
than most integrations need and would increase the impact of disclosure.

## Decision

- iOS users authenticate with Supabase and a user JWT.
- A single-use six-digit binding code creates a scoped `bw_agent_...` token for
  project and configuration management.
- A project-scoped `bw_live_...` Ingest token can submit Events and update live
  Surfaces without receiving account-wide management access.
- Tokens are shown only when created, stored as hashes server-side, and passed
  to runtimes through secret stores.
- Supabase service-role keys and APNs private keys exist only in Worker secrets.
  iOS receives a Supabase publishable key, never a server credential.

## Consequences

- Runtime compromise can be contained by revoking one project token.
- Agent integrations must deliberately hand off to a narrower Ingest token for
  production use.
- Documentation and diagnostics must never print or persist token values.
- New capabilities require an explicit scope and authorization review.
