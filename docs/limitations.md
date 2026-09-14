# Limitations

ParcelFlow is intentionally scoped for explanation and repeatability.

It is not production-ready because it does not include:

- customer authentication or authorization;
- multi-tenant isolation;
- real courier, address, mapping, or payment integrations;
- route optimization or mobile applications;
- malware scanning of uploaded proofs;
- high availability, zone redundancy, or multi-region failover;
- a service mesh, API gateway, or edge protection;
- production backup restoration exercises;
- unrestricted public access;
- automatic cloud deployment from pull requests.

RabbitMQ and Azure Service Bus are not protocol-compatible. ParcelFlow contains
explicit adapters with common application semantics; Score provides resource
configuration and platform mapping, not protocol translation.

`score-compose` does not enforce HTTP probes or container resource limits.
Local tests check health directly, while Kubernetes enforces generated policy.

`score-k8s` is a reference implementation and stores generation state. Azure
deployment persists this state privately because discarding it can change
generated identities or credentials.

AKS creates a managed node resource group in addition to the user-managed demo
resource group. This is an Azure platform requirement and the only intentional
exception to the single-resource-group presentation.
