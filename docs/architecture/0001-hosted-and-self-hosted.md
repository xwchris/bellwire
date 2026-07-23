# ADR-0001: One protocol, two deployment modes

Status: Accepted

## Context

Bellwire is both a managed product and a project users can run on infrastructure
they control. Fork-specific URLs, Apple identifiers, and cloud resources must
not require a permanent source-code fork or access to Bellwire Cloud secrets.

## Decision

The official hosted build and self-hosted builds share the same API routes,
Event Spec, Surface model, Agent token scopes, and delivery semantics.

Deployment-specific values are supplied through Worker configuration and iOS
build settings. Self-hosted local configuration is ignored by Git. A fork uses
its own Apple Team, Bundle IDs, URL scheme, Supabase project, Cloudflare Worker,
Queues, and APNs authentication key.

The marketing website, billing operations, hosted deployment secrets, and
commercial administration remain outside this repository.

## Consequences

- Features must be evaluated against both deployment modes.
- The public API cannot quietly depend on a private Bellwire Cloud service.
- Bellwire Cloud can charge for managed operation, capacity, and commercial
  features without weakening the complete self-hosted path.
- Forks cannot use Bellwire signing identities or imply official status.
