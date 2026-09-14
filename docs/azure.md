# Azure deployment

## Safety model

The Azure path is intentionally manual. It deploys into an existing resource
group through a deployment stack and does not delete the resource group.

Always verify the displayed tenant, subscription, resource group, region, and
planned changes before approving deployment.

AKS creates a managed node resource group outside the user-created resource
group. Azure owns that group and removes it with the cluster.

## Required permissions

The operator needs permission to:

- create resources and deployment stacks in the target resource group;
- register `Microsoft.DBforPostgreSQL` and `Microsoft.ServiceBus`;
- create role assignments;
- inspect quota and available AKS versions;
- recover or optionally purge the demo Key Vault;
- create a resource-group budget.

The deployment scripts verify these operations before changing infrastructure.

## Preflight and what-if

```powershell
$tenantId = '<tenant-id>'
$subscriptionId = '<subscription-id>'
$operatorPrincipalId = az ad signed-in-user show --query id --output tsv
$resourceGroup = 'rg-score-parcelflow-demo'
$location = 'centralus'
$kubernetesVersion = '1.35'
$confirmationToken = "$tenantId/$subscriptionId/$resourceGroup/$location"

.\scripts\azure\preflight.ps1 `
  -TenantId $tenantId -SubscriptionId $subscriptionId `
  -OperatorPrincipalId $operatorPrincipalId `
  -ResourceGroupName $resourceGroup -Location $location `
  -KubernetesVersion $kubernetesVersion `
  -ConfirmationToken $confirmationToken

.\scripts\azure\what-if.ps1 `
  -TenantId $tenantId -SubscriptionId $subscriptionId `
  -OperatorPrincipalId $operatorPrincipalId `
  -ResourceGroupName $resourceGroup -Location $location `
  -KubernetesVersion $kubernetesVersion `
  -ConfirmationToken $confirmationToken
```

Preflight checks the active tenant and subscription, resource group, providers,
regional VM restrictions, quota, and a supported AKS minor version.
It registers missing required providers, so it intentionally changes
subscription-level provider registration state.

The Azure CLI currently exposes resource-group template what-if rather than a
deployment-stack deletion preview. Review both the what-if output and
`az stack group show --name score-parcelflow --resource-group $resourceGroup`
before removing resources from the Bicep template.

Deploy the complete application with an immutable tag:

```powershell
.\scripts\azure\deploy.ps1 `
  -TenantId $tenantId -SubscriptionId $subscriptionId `
  -OperatorPrincipalId $operatorPrincipalId `
  -ResourceGroupName $resourceGroup -Location $location `
  -KubernetesVersion $kubernetesVersion `
  -BudgetContact '<email-address>' `
  -ConfirmationToken $confirmationToken `
  -DeployApplication -ImageTag "demo-$(Get-Date -Format yyyyMMdd-HHmm)"
```

The Azure path requires Azure CLI with Bicep, `kubectl`, `kubelogin`, and
`score-k8s`.

The resource group's metadata region is `westus2`, but workload resources use
`centralus`. Resource groups can contain resources from other regions. This
subscription currently restricts PostgreSQL Flexible Server creation in
`westus2`, while `centralus` supports the required PostgreSQL and AKS SKUs.

## Deployment order

1. Network, static egress, identities, data services, registry, and monitoring
2. AKS control-plane permissions and cluster
3. OIDC federated credentials and data-plane role assignments
4. Key Vault CSI profiles and least-privilege PostgreSQL bootstrap
5. Immutable application images in ACR
6. Score state restore or first-run initialization
7. Sequential `score-k8s` generation and apply
8. Rollout checks and smoke test

Azure role assignments may take several minutes to propagate. Scripts retry
bounded operations and surface the failing assignment rather than hiding errors.

## Access

The default path is:

```powershell
kubectl -n parcelflow port-forward service/parcel-api 8080:8080
```

This avoids publishing unauthenticated mutation and upload APIs. A temporary
public profile may be added for a supervised presentation only when it includes
TLS, an IP allowlist, request limits, rate limiting, and an expiration time.

## Secrets

Two PostgreSQL credentials are generated without command-line arguments:

- an administrator credential mounted only by the bootstrap Job;
- an application credential mounted only by runtime workloads.

Both are stored in Key Vault. Separate identities and
`SecretProviderClass` resources prevent the application from reading the
administrator credential. Generated Score state contains only Kubernetes
Secret references.

The default deployment credential file is
`.azure/parcelflow.credentials.secrets.json`. It is permission-restricted,
ignored by Git and Docker build contexts, and reused for redeployments so an
infrastructure-only update cannot silently rotate the database password. The
bootstrap Job, service account, SecretProviderClass, and federated credential
are removed after the database role is configured.

## Score state

The private `score-state` container is separate from application proof data.
Deployment automation:

1. grants only the deployment identity access;
2. temporarily permits the authenticated runner IPv4 address through the firewall;
   when a dual-stack client reaches Blob Storage over IPv6, temporarily changes
   the firewall default to allow authenticated requests because this account
   type does not support IPv6 rules;
3. acquires an object lease;
4. downloads state or initializes it when absent;
5. uploads updated state;
6. releases the lease and restores the default-deny firewall with no temporary
   network rules. Shared-key and anonymous Blob access remain disabled
   throughout.

## Stop and teardown

Stopping AKS reduces compute cost but does not stop every billable service. See
[Cost](cost.md).

Use the repository teardown script to delete the deployment stack while
preserving the resource group. It verifies the stack's resources and the
AKS-managed node resource group are absent. Soft-deleted Key Vault recovery is
the default for redeployment; permanent purge is explicit and permission-gated.
