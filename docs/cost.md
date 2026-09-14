# Cost controls

Azure prices vary by region, agreement, currency, and date. Review the current
[Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)
before deployment rather than relying on a static total in this repository.

## Billable components

The principal cost drivers are:

- AKS worker virtual machines and disks
- Azure Database for PostgreSQL Flexible Server and storage
- Service Bus Standard
- Log Analytics ingestion and retention
- ACR, Blob Storage, public IP, and network traffic
- Key Vault operations

AKS control-plane Free tier does not make the cluster free; worker nodes remain
billable.

## Baseline controls

- AKS Free tier with `Standard_D2as_v7`, initially two nodes, autoscaling 1-3
- PostgreSQL `Standard_B1ms`, 32 GiB, no high availability
- ACR Basic
- Service Bus Standard with one queue
- Standard LRS storage
- Log Analytics 30-day retention, daily cap, and filtered collection
- Ten-percent application telemetry sampling outside smoke tests
- Seven-day proof-of-delivery lifecycle deletion
- No availability zones, premium messaging, NAT Gateway, or public ingress
- Maximum recommended deployment duration: 24 hours

Deployment accepts a budget contact and creates a USD 50 monthly budget with
alerts at 50, 80, and 100 percent. Budgets alert; they do not automatically stop
or delete resources.

## Before and after a demo

Inspect current cost:

```powershell
az consumption usage list `
  --start-date (Get-Date).AddDays(-7).ToString('yyyy-MM-dd') `
  --end-date (Get-Date).ToString('yyyy-MM-dd')
```

Stop eligible services when retaining the environment temporarily:

```powershell
.\scripts\azure\Set-ComputeState.ps1 `
  -Action Stop `
  -TenantId $tenantId -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroup -Location $location `
  -ConfirmationToken $confirmationToken `
  -OutputsPath .\.azure\infra-outputs.json
```

Stopping AKS and PostgreSQL does not eliminate Service Bus, ACR, Storage, Key
Vault, Log Analytics, disk, IP, or retained-backup charges. Prefer complete
deployment-stack teardown after the review.
