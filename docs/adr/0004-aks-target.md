# ADR 0004: Target AKS

- Status: Accepted
- Date: 2026-09-13

## Decision

Use AKS as the Azure target because ParcelFlow demonstrates `score-k8s`.

## Consequences

AKS costs and operational surface are larger than Azure Container Apps would
require for this application alone. The cluster is ephemeral, cost-controlled,
and accessed by port-forward by default. Azure creates a managed node resource
group outside the primary resource group.
