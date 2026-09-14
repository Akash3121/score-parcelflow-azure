# Architecture

## System context

```mermaid
flowchart TB
    User[Demo user or reviewer]
    GitHub[GitHub repository and Actions]
    Local[Local Docker environment]
    Azure[Azure resource group]

    User --> GitHub
    User --> Local
    User --> Azure
    GitHub --> Local
    GitHub -. manually approved deployment .-> Azure
```

ParcelFlow demonstrates the same workload definitions against two platform
profiles. Local resources optimize for convenience; Azure resources optimize
for managed operation, workload identity, and explicit lifecycle control.

## Runtime containers

```mermaid
flowchart LR
    Browser -->|HTTP| API[parcel-api]
    Simulator -->|HTTP| API
    API -->|SQL transaction| PostgreSQL[(PostgreSQL)]
    API -->|publish outbox| Queue[[Command queue]]
    Queue -->|at-least-once| Worker[delivery-worker]
    Worker -->|idempotent transition| PostgreSQL
    API -->|private object| Storage[(Proof storage)]
```

### `parcel-api`

The API owns validation, reads, parcel creation, command acceptance,
proof-of-delivery access, schema migration, and the transactional outbox
publisher. The embedded UI uses the same public API.

### `delivery-worker`

The worker consumes at-least-once command messages and records a transition only
when the command has not already been applied. Duplicate delivery therefore
does not create duplicate timeline events.

### Simulator and smoke client

The simulator is opt-in and operates only through HTTP. It never shares
application internals or database access. The smoke client uses unique test
identifiers and bounded polling so it remains deterministic while the simulator
is running.

## Parcel lifecycle

```mermaid
stateDiagram-v2
    [*] --> label_created
    label_created --> picked_up
    picked_up --> at_sorting_center
    at_sorting_center --> in_transit
    in_transit --> out_for_delivery
    out_for_delivery --> delivered
    delivered --> [*]
```

Each transition records the prior state, new state, command identifier,
timestamp, and correlation identifier.

## Advance-delivery sequence

```mermaid
sequenceDiagram
    participant U as User
    participant A as parcel-api
    participant D as PostgreSQL
    participant Q as Queue
    participant W as delivery-worker

    U->>A: POST advance + Idempotency-Key
    A->>D: Insert command and outbox in one transaction
    D-->>A: Accepted
    A-->>U: 202 Accepted
    A->>Q: Publish pending outbox event
    Q-->>W: Deliver command
    W->>D: Apply transition if command is new
    D-->>W: Commit event and command receipt
    W-->>Q: Acknowledge
    U->>A: GET parcel
    A->>D: Read parcel and timeline
    A-->>U: Updated state
```

Publishing may occur more than once if the API crashes after publishing but
before marking the outbox row complete. The worker's command receipt makes this
safe.

## Proof-of-delivery sequence

```mermaid
sequenceDiagram
    participant U as User
    participant A as parcel-api
    participant S as Object storage
    participant D as PostgreSQL

    U->>A: Upload PDF/JPEG/PNG
    A->>A: Validate type and one MiB limit
    A->>A: Compute SHA-256 while streaming
    A->>S: Store private object
    A->>D: Save immutable proof metadata
    A-->>U: Checksum and media type
    U->>A: Download proof
    A->>D: Authorize by parcel record
    A->>S: Stream private object
    A-->>U: Safe attachment response
```

## Local and Azure deployment

```mermaid
flowchart TB
    Score[Unchanged Score workload files]
    Compose[score-compose]
    K8s[score-k8s]
    LocalProvisioners[Local provisioners]
    AzureProvisioners[Azure provisioners]
    Docker[Docker Compose]
    AKS[Azure Kubernetes Service]

    Score --> Compose
    Score --> K8s
    LocalProvisioners --> Compose
    AzureProvisioners --> K8s
    Compose --> Docker
    K8s --> AKS
```

See [ADR 0001](adr/0001-score-as-workload-contract.md) for the boundary and
[Score mapping](score.md) for concrete outputs.

## Azure deployment topology

Azure keeps user-managed resources in one resource group. AKS creates one
additional managed node resource group as an Azure platform requirement.

```mermaid
flowchart TB
    subgraph RG[rg-score-parcelflow-demo]
      AKS[AKS]
      ACR[ACR]
      PG[PostgreSQL Flexible Server]
      SB[Service Bus]
      ST[Storage]
      KV[Key Vault]
      LAW[Log Analytics]
      VNET[VNet and private DNS]
      IDs[Managed identities]
    end

    subgraph NRG[AKS-managed node resource group]
      Nodes[VM scale set and load-balancer resources]
    end

    AKS --> Nodes
    AKS --> ACR
    AKS --> PG
    AKS --> SB
    AKS --> ST
    AKS --> KV
    AKS --> LAW
```
