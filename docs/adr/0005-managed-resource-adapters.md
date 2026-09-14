# ADR 0005: Use explicit managed-resource adapters

- Status: Accepted
- Date: 2026-09-13

## Decision

Use RabbitMQ and Azurite locally, and Service Bus and Blob Storage in Azure.
Select explicit application adapters using provisioner outputs.

## Consequences

The demo shows that Score can bind abstract workload requirements to different
platform services without falsely claiming protocol compatibility. Adapter
contract and failure-semantics tests are required for both implementations.
