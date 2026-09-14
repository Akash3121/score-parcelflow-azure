# ADR 0001: Use Score as the workload contract

- Status: Accepted
- Date: 2026-09-13

## Decision

Keep one platform-neutral Score file per deployed workload. Use provisioners and
platform automation to satisfy resource requirements locally and in Azure.

## Consequences

Application intent remains reviewable without Docker Compose or Kubernetes
syntax. Platform teams can change resource implementations without editing the
workloads. Azure infrastructure, identity, networking, and policy remain
outside Score by design.
