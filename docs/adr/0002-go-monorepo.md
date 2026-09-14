# ADR 0002: Use a Go monorepo

- Status: Accepted
- Date: 2026-09-13

## Decision

Implement the API, worker, simulator, and smoke client in one Go module. Embed a
small vanilla web interface in the API.

## Consequences

The demo has one toolchain, fast static builds, reusable domain code, and no
frontend dependency pipeline. It intentionally avoids demonstrating independent
team release cycles or a rich client framework.
