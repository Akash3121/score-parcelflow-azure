# Operations runbook

## Health

```powershell
Invoke-RestMethod http://localhost:8080/health/live
Invoke-RestMethod http://localhost:8080/health/ready
```

Liveness confirms the process can serve requests. Readiness additionally checks
required runtime dependencies and successful schema migration.

## Kubernetes status

```powershell
kubectl -n parcelflow get pods,services
kubectl -n parcelflow rollout status deployment/parcel-api
kubectl -n parcelflow rollout status deployment/delivery-worker
```

## Correlated logs

Use the request ID returned by the API or the command correlation ID:

```powershell
kubectl -n parcelflow logs deployment/parcel-api | Select-String <correlation-id>
kubectl -n parcelflow logs deployment/delivery-worker | Select-String <correlation-id>
```

In Azure, query the same identifier in Log Analytics after ingestion.

## Queue backlog or dead letters

Check whether the worker is ready and whether its identity has receiver access.
Inspect active and dead-letter counts in Service Bus. A poison message must be
preserved for diagnosis rather than acknowledged as successful.

## Database readiness

Verify private DNS resolution from a pod, network access, CSI secret
synchronization, and the application role. Migration failure intentionally
keeps the API unready.

## Proof upload failure

Confirm:

- media type is PDF, JPEG, or PNG;
- body is no larger than one MiB;
- the API identity has Blob Data Contributor on the proof container;
- the private container exists;
- repeated content has the expected checksum.

## Restart resilience

```powershell
kubectl -n parcelflow rollout restart deployment/parcel-api
kubectl -n parcelflow rollout restart deployment/delivery-worker
```

After rollout, rerun the smoke test. Parcel state must persist and a repeated
idempotency key must not create another transition.

## Score regeneration

Do not delete Azure `.azure/score-work/.score-k8s` state during deployment. Use
the deployment script, which restores the private state object, obtains a
lease, regenerates, and uploads it.

Compose recreates state for deterministic generation. Kind preserves its
separate state during regeneration to keep Kubernetes selectors stable.

## Teardown verification

Run the teardown script and verify:

- the deployment stack no longer exists;
- no repository-tagged resources remain;
- the AKS-managed node resource group is absent;
- no temporary Storage or Service Bus firewall rule remains;
- the resource group itself still exists;
- any soft-deleted Key Vault is either recoverable or explicitly purged.
