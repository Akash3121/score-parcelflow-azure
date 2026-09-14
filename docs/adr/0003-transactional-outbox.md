# ADR 0003: Use a transactional outbox

- Status: Accepted
- Date: 2026-09-13

## Decision

Persist delivery commands and outbox records in the same PostgreSQL transaction.
Publish asynchronously and make worker transitions idempotent.

## Consequences

The demo can explain and test crash recovery and duplicate delivery. It accepts
at-least-once delivery and does not claim distributed exactly-once semantics.
