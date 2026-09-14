# ParcelFlow implementation plan

## Goal

Build a reproducible parcel-delivery reference application that demonstrates how
the same Score workload definitions run locally with `score-compose` and on
Azure Kubernetes Service with `score-k8s`.

The repository must be understandable without private context, contain no
committed credentials or generated Score state, and provide deterministic
setup, validation, demonstration, and teardown paths.

## Demo journey

1. Start ParcelFlow locally from a fresh clone.
2. Open the UI and inspect deterministic sample parcels.
3. Create a shipment and request delivery progression.
4. Observe asynchronous dispatch and tracking events.
5. Upload and retrieve a fictional proof-of-delivery receipt.
6. Run a deterministic smoke test that verifies idempotency.
7. Generate Kubernetes manifests from the unchanged Score files.
8. Provision the Azure platform in one resource group.
9. Deploy the same workloads to AKS and repeat the smoke test.
10. Remove all deployed resources through a documented cleanup command.

## Application architecture

ParcelFlow uses two Go workloads and one opt-in demo command:

| Workload | Responsibility |
| --- | --- |
| `parcel-api` | Embedded web UI, REST API, validation, parcel queries, command acceptance, health endpoints, and an outbox publisher |
| `delivery-worker` | Consumes delivery commands, performs deterministic and idempotent state transitions, and records tracking events |
| `cmd/simulator` | Runs an opt-in, deterministic scan sequence through the API; it is not a continuously deployed workload |

Platform resources:

| Contract | Local implementation | Azure implementation |
| --- | --- | --- |
| `postgres` | PostgreSQL container | Azure Database for PostgreSQL Flexible Server |
| `message-queue` | RabbitMQ | Azure Service Bus queue |
| `object-store` | Azurite Blob service | Azure Blob Storage |
| `service-port` | Docker Compose service discovery | Kubernetes Service discovery |

The application selects explicit resource adapters from provider information
returned by the platform provisioner. Score supplies the resource contract and
configuration; it does not make RabbitMQ and Service Bus protocols compatible.
The application adapters provide that portability and share at-least-once
delivery, deduplication, retry, and poison-message semantics.

The custom resource output contracts are:

| Contract | Required outputs |
| --- | --- |
| `message-queue` | `provider`, `endpoint`, `queue`, `credentialMode`, `username`, `password` |
| `object-store` | `provider`, `endpoint`, `container`, `credentialMode`, `accountName`, `accountKey` |

Optional credentials are emitted as empty strings for workload-identity
profiles so every placeholder resolves on both platforms.

The API and worker declare identical `type`, `class`, and `id` values for the
shared PostgreSQL database and message queue. This prevents Score from
provisioning separate resources for each workload.

## Azure architecture

All user-managed resources are deployed into `rg-score-parcelflow-demo`. The
resource group metadata is stored in `westus2`; workload resources use
`centralus` because this subscription restricts PostgreSQL Flexible Server
creation in `westus2`:

- Azure Kubernetes Service Free tier with OIDC and workload identity
- Azure Container Registry Basic
- Azure Database for PostgreSQL Flexible Server
- Azure Service Bus Standard with one queue and dead-letter queue
- General-purpose v2 Storage Account with separate private proof and deployment-state containers
- Azure Key Vault for the generated PostgreSQL application credential
- Log Analytics workspace and Container Insights
- User-assigned managed identities and narrowly scoped role assignments
- Virtual network with AKS and delegated PostgreSQL subnets

AKS uses a static outbound public IP. Service Bus Standard remains on a public
endpoint because it does not support private endpoints; its firewall permits
only the AKS outbound IP, local authentication is disabled, and separate
sender/receiver identities receive narrowly scoped roles.

Storage permits the AKS subnet through a service endpoint, denies anonymous
blob access, and disables shared-key authorization. Deployment automation adds
the authenticated operator or CI runner IP only while transferring Score state,
then removes the rule in a `finally` block. ACR Basic retains its
public endpoint, disables admin and anonymous access, and grants `AcrPull` only
to the kubelet identity.

Service Bus and Blob access use workload identity. Separate PostgreSQL
administrator and least-privilege application credentials are generated outside
command arguments, passed to Bicep as secure parameters, and written directly
to Key Vault. The application never runs as the server administrator.

AKS enables the Secrets Store CSI Driver add-on and secret rotation. Bicep
creates two isolated Key Vault access paths:

- A bootstrap-only identity and `SecretProviderClass` expose the administrator
  and application credentials only to the idempotent database bootstrap Job.
- A runtime identity and `SecretProviderClass` expose only the application
  credential to the API and worker and maintain the synchronized Kubernetes
  Secret referenced by the custom Score provisioner through `encodeSecretRef`.

The bootstrap Job uses the administrator credential to create or update the
application role and database grants. Application pods cannot read the
administrator secret, and the provisioner never emits raw credentials.

Key Vault uses RBAC, denies public access by default, and permits the AKS subnet
through a service endpoint. Credential rotation updates the PostgreSQL role
first, updates Key Vault second, waits for CSI synchronization, and then rolls
the workloads. Plaintext credentials do not enter Bicep outputs, generated
manifests, Score state, command history, or CI logs.

The baseline uses `Standard_D2as_v7` nodes without zone pinning, autoscaling
from one to three nodes with two initially requested, and PostgreSQL
`Standard_B1ms` with a documented `Standard_B2s` fallback. The deployment pins
a supported AKS minor version after preflight validation rather than relying on
the regional default.

AKS necessarily creates a platform-managed node resource group. The
user-managed resources remain in `rg-score-parcelflow-demo`; the managed node
resource group is named deterministically, documented as the sole exception,
and removed when AKS is deleted.

PostgreSQL uses the private DNS zone
`privatelink.postgres.database.azure.com`, an explicit VNet link, and an
explicit Flexible Server association to the delegated database subnet.

## Score boundary

The files in `deploy/score/` are the workload source of truth and remain
byte-identical across local and Azure targets. They contain:

- containers and images
- environment variables assembled from resource outputs
- service ports
- health probes
- CPU and memory requests and limits
- abstract resource requirements

The following remain outside Score:

- Azure resource creation
- networking and identity
- public exposure
- Kubernetes service accounts and security policy
- resource-provider-specific connection details
- replica counts and environment policy

Those concerns are implemented with Bicep, custom resource provisioners, Score
overrides, and narrow `score-k8s` patch templates.

Generated `.score-compose`, Compose manifests, Kubernetes manifests, deployment
outputs, and secrets are ignored by Git. Compose recreates state for
deterministic runs; Kind and Azure use separate persistent score-k8s working
directories. Azure state is restored from and uploaded to a dedicated private
deployment-state container using Entra authorization. The deployment identity
has access to this container; application identities do not. Proof-of-delivery
objects use a separate private container to which only the API identity has
data-plane access. A missing state object is treated as the first deployment:
the script runs `score-k8s init`, generates state, and uploads it. Existing
state is downloaded before generation. The deployment identity receives Blob
Data Contributor, scripts use an object lease to reject concurrent deployment,
and the temporary runner-IP firewall exception is always removed. The custom
Azure provisioners contain no raw secret values.

Each Score file uses `image: .`. Generation runs once per workload so the
correct image/build override can be supplied. Neither workload declares a
fabricated API dependency: the worker consumes the queue and database directly.

## API and data contract

Primary endpoints:

- `GET /health/live`
- `GET /health/ready`
- `GET /api/v1/build`
- `GET /api/v1/parcels`
- `POST /api/v1/parcels`
- `GET /api/v1/parcels/{trackingId}`
- `POST /api/v1/parcels/{trackingId}/commands/advance`
- `POST /api/v1/parcels/{trackingId}/proof-of-delivery`
- `GET /api/v1/parcels/{trackingId}/proof-of-delivery`

Mutations support an idempotency key. Errors use RFC 7807 problem details,
timestamps use RFC 3339 UTC, and request IDs are returned to callers.

The lifecycle is:

`label_created -> picked_up -> at_sorting_center -> in_transit ->
out_for_delivery -> delivered`

The database contains parcel, event, command, and transactional outbox records.
Schema migration and fictional seed data are versioned and idempotent.
Migrations run during API startup under a PostgreSQL advisory lock; failed
migrations fail readiness and repeated or concurrent startup is safe.

Proof-of-delivery accepts only a small fixed set of image/PDF media types,
streams data with a one MiB limit, stores objects privately, records a SHA-256
checksum, and returns a safe attachment filename. Repeated upload behavior is
idempotent for matching content and rejects conflicting content.

## Delivery phases

### 1. Repository foundation

- Establish Go module, directory layout, license, contribution and security
  files, formatting, and ignore rules.
- Record architectural decisions and this reviewed implementation plan.

### 2. Application

- Implement domain lifecycle and validation.
- Implement PostgreSQL persistence and transactional outbox.
- Implement local and Azure message-bus adapters.
- Implement local and Azure object-store adapters.
- Implement API, worker, embedded UI, opt-in simulator, and smoke-test command.
- Add unit, repository integration, and HTTP contract tests.
- Test outbox recovery, duplicate delivery, worker restarts, poison-message
  dead-lettering, and uniqueness of commands and tracking events.

### 3. Score and local platform

- Add one Score file per workload.
- Add local provisioners for the queue and object-store contracts.
- Generate the application through `score-compose`.
- Validate the complete local journey and idempotency behavior.
- Validate health endpoints explicitly because score-compose validates but
  ignores HTTP probes and CPU/memory policy.
- Deploy the same generated workloads to Kind in CI and run the same smoke
  executable used locally and on AKS.
- Add an explicit Kind `score-k8s` provisioner profile that creates PostgreSQL,
  RabbitMQ, and Azurite manifests for the custom resource contracts. CI builds
  and loads both workload images into Kind before sequential generation.

### 4. Azure platform

- Add modular Bicep with deterministic globally unique suffixes, tags,
  conservative SKUs, stable API versions, and no secret outputs.
- Register `Microsoft.DBforPostgreSQL` and `Microsoft.ServiceBus` during a
  subscription-level preflight and wait for `Registered`.
- Register required resource providers and run Bicep validation and `what-if`.
- Deploy infrastructure into the existing resource group through an Azure
  deployment stack so repository-owned resources can be removed without
  deleting the resource group.
- Build immutable container images and push them to ACR.

### 5. AKS platform mapping

- Create workload identities and service accounts.
- Enable Key Vault CSI, create the `SecretProviderClass`, and run the
  least-privilege PostgreSQL bootstrap Job.
- Install custom Azure Score provisioners and security patch templates.
- Generate and apply manifests through `score-k8s`.
- Run database migrations, seed data, and the cloud smoke test.
- Default to `kubectl port-forward`. Public exposure is a separate, expiring
  profile and is not required for validation.

### 6. Documentation and automation

- Add architecture, deployment, and sequence diagrams in Mermaid.
- Add quickstart, demo script, Score mapping explanation, Azure guide,
  troubleshooting, runbook, security model, limitations, and cost guidance.
- Add CI for formatting, tests, images, Score generation, and Bicep validation.
- Keep Azure deployment manually triggered and protected from untrusted forks.
- Pin the Go toolchain, Score CLIs, base images, GitHub Actions commit SHAs,
  Bicep API versions, and all deployment dependencies; do not use `latest`.

### 7. Independent review and correction

- Review application correctness and failure handling.
- Review Score portability and generated output.
- Review Azure security, identity, networking, cost, and teardown.
- Review the fresh-clone user journey and documentation.
- Resolve findings and rerun end-to-end validation.

## Acceptance criteria

- A fresh clone can run locally without a handwritten Compose file.
- The same tracked Score files generate both local and AKS workloads.
- The smoke test creates a parcel, advances it asynchronously, verifies the
  exact resulting state, retries the same command, and proves no duplicate
  transition occurred.
- The smoke test uploads a fixed proof-of-delivery fixture, retrieves it,
  verifies checksum and content type, and proves repeated-upload semantics.
- Crash/retry tests cover publish-before-outbox-acknowledgement, duplicate queue
  delivery, pending outbox recovery, worker restart, and poison-message DLQ.
- Workloads run as non-root on AKS with probes and resource constraints; local
  tests call health endpoints directly.
- No committed file contains Azure credentials, generated Score state, or
  generated manifests.
- Azure Service Bus and Blob access use managed identity, PostgreSQL credentials
  originate in Key Vault, and no raw secret enters Score state.
- The application survives workload restarts while retaining parcel state.
- Structured logs propagate request and command correlation IDs through the
  API, outbox, Service Bus, and worker into Log Analytics. Alerts cover DLQ
  depth and workload failures. The baseline does not claim distributed tracing.
- The Azure deployment completes through port-forward; optional public mode has
  an IP allowlist, TLS, rate and upload limits, and automatic expiry.
- Infrastructure creation and deployment-stack teardown are idempotent and
  preserve `rg-score-parcelflow-demo`; AKS's managed node resource group is
  verified absent after teardown.
- The repository documents cost assumptions and explicitly identifies
  non-production shortcuts.
- Restoring the private Azure Score-state object and regenerating manifests does
  not change stable resource identities.

## Cost and safety controls

- Use low-cost demo SKUs without zone redundancy or high availability.
- Use port-forward by default; public ingress is optional and time-bounded.
- Set Log Analytics to 30-day retention, apply a daily ingestion cap and data
  collection filters, and sample traces at ten percent outside smoke tests.
- Create a USD 50 monthly resource-group budget using a deployment-time contact
  parameter with alerts at 50, 80, and 100 percent.
- Delete proof-of-delivery blobs after seven days through a prefix/container
  scoped lifecycle policy; deployment-state objects are excluded.
- Document a maximum 24-hour demo deployment and provide explicit AKS and
  PostgreSQL stop/start commands, noting that Service Bus, ACR, Storage, Key
  Vault, and Log Analytics may continue to incur cost.
- Parameterize capacity and allow the AKS cluster to be stopped between demos.
- Tag resources with `project=score-parcelflow`, `environment=demo`, and an
  expiration marker.
- Do not add resource locks or Key Vault purge protection because this is an
  ephemeral demo environment. Teardown deletes the deployment stack, verifies
  repository-owned resources and the AKS node resource group are absent, and
  optionally purges the soft-deleted Key Vault name. A normal redeployment
  detects and recovers a matching soft-deleted vault before applying Bicep;
  purge is available only to operators with the required permission.
- Verify the target subscription, tenant, and resource group before every
  deployment or deletion operation.

## Deployment ordering

1. Verify tenant, subscription, resource group, quota, regional SKU availability,
   and the pinned AKS version.
2. Register required subscription resource providers and wait for completion.
3. Deploy network, static outbound IP, identities, data services, Key Vault,
   private DNS, registry, and monitoring.
4. Assign network permissions to the AKS control-plane identity.
5. Deploy AKS and obtain its OIDC issuer.
6. Create federated workload credentials and role assignments, retrying until
   Azure RBAC propagation is observable.
7. Configure Key Vault CSI and run the idempotent PostgreSQL role/bootstrap Job.
8. Build and push immutable images.
9. Restore or initialize Score state, generate manifests sequentially, and
   upload updated state under a Blob lease.
10. Apply workloads and allow advisory-lock migrations to complete.
11. Run local-equivalent smoke, restart, duplicate-delivery, storage, and
    observability checks.
