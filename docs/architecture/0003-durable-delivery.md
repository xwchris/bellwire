# ADR-0003: Durable acceptance before asynchronous delivery

Status: Accepted

## Context

An Event is useful as durable history even when push delivery is delayed. Queue
or APNs failures must not cause a committed source operation to be reported as
failed, but the API also must not claim that an iPhone displayed a notification.

## Decision

The ingest path validates and stores an idempotent Event before dispatching
delivery work. Cloudflare Queue performs asynchronous delivery. Delivery
attempts are recorded separately and retried only when the failure is considered
retryable.

If Queue submission fails after Event persistence, the Event remains accepted
and delivery health records a retryable degraded state. Replaying the same
project and idempotency key reuses the original Event and can recover dispatch
without duplicating history.

`accepted_by_apns` means APNs accepted the provider request. Only a user or
device-side signal can confirm visible presentation.

## Consequences

- Source integrations need stable business idempotency keys.
- Queue handoff and APNs outcomes remain observable independently of Event
  acceptance.
- A test Event proves configuration, not production-source integration.
- Documentation and UI must preserve the distinction between stored, queued,
  accepted by APNs, failed, and visibly presented.
