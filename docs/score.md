# How ParcelFlow uses Score

## Workload source of truth

ParcelFlow keeps one Score file for each deployed workload:

- `deploy/score/parcel-api.score.yaml`
- `deploy/score/delivery-worker.score.yaml`

These files are used without Azure-specific edits by `score-compose`,
`score-k8s` on Kind, and `score-k8s` on AKS.

Score describes workload intent:

- container images and environment variables;
- ports and health probes;
- resource requests and limits;
- PostgreSQL, queue, and object-storage requirements.

It does not create the Azure subscription, network, AKS cluster, identity
assignments, managed data services, or monitoring resources. Bicep owns those
platform responsibilities.

## Shared resource identity

Resources used by more than one workload have explicit matching `type`, `class`,
and `id` fields:

| Resource | Type | Class | ID |
| --- | --- | --- | --- |
| Parcel database | `postgres` | `default` | `parcelflow-database` |
| Delivery commands | `message-queue` | `default` | `parcelflow-commands` |
| Delivery proofs | `object-store` | `default` | `parcelflow-proofs` |

Without the explicit IDs, each workload could receive an independent resource.

## Custom contracts

`message-queue` and `object-store` intentionally demonstrate custom Score
provisioners.

### Message queue outputs

| Output | Meaning |
| --- | --- |
| `provider` | `rabbitmq` or `azure-servicebus` |
| `endpoint` | Broker or namespace endpoint |
| `queue` | Queue name |
| `credentialMode` | `password` or `workload-identity` |
| `username` | Local credential or empty string |
| `password` | Local credential, secret reference, or empty string |

Score supplies a consistent configuration contract. Application adapters handle
the real protocol differences between RabbitMQ and Azure Service Bus.

### Object-store outputs

| Output | Meaning |
| --- | --- |
| `provider` | `azurite` or `azure-blob` |
| `endpoint` | Blob service endpoint |
| `container` | Private proof container |
| `credentialMode` | `shared-key` or `workload-identity` |
| `accountName` | Storage account name |
| `accountKey` | Local key, secret reference, or empty string |

## Target mappings

| Requirement | Compose | Kind | Azure |
| --- | --- | --- | --- |
| PostgreSQL | Default Score provisioner | Default Score provisioner | Attachment provisioner for Flexible Server |
| Queue | RabbitMQ container | RabbitMQ resources | Service Bus attachment |
| Object store | Azurite container | Azurite resources | Blob attachment |
| Credentials | Generated local state | Generated Kind state | Workload identity or Key Vault secret reference |

Generated state may contain sensitive information. `.score-compose`, `.kind`,
and `.azure` are ignored. Kind and Azure use separate score-k8s working
directories so their resource mappings cannot collide. Azure Score state is
stored in a dedicated private Blob container and restored before regeneration.

## Generation behavior

Both implementations are stateful and additive. Compose recreates local/CI
state. Kind preserves state during regeneration and removes it with the cluster.
Azure scripts restore persistent private state.

Each workload is generated separately because its `image: .` placeholder must
receive a workload-specific build context or immutable image:

```powershell
score-k8s generate .\deploy\score\parcel-api.score.yaml `
  --image <registry>/parcel-api:<commit>

score-k8s generate .\deploy\score\delivery-worker.score.yaml `
  --image <registry>/delivery-worker:<commit>
```

`score-compose` validates but does not enforce HTTP probes or container resource
limits. Local smoke tests therefore call health endpoints directly. Kubernetes
enforces the generated probes and resource policy.

## Inspecting generated output

Generated manifests are intentionally not committed. Reviewers can regenerate
them and inspect the platform differences:

```powershell
.\scripts\local\generate.ps1
Get-Content .\compose.yaml

.\scripts\local\kind-generate.ps1
Get-Content .\manifests.yaml
```

The Azure profile attaches managed resources rather than creating database,
queue, or storage containers inside Kubernetes.
