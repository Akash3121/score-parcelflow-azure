# Demonstration script

This walkthrough is designed for a 10-15 minute maintainer review.

## 1. Explain the contract

Open the two files in `deploy/score` and point out:

- no Docker Compose or Azure syntax;
- explicit shared resource IDs;
- environment variables assembled from resource outputs;
- the same health, port, and resource intent for every target.

## 2. Start locally

```powershell
.\scripts\local\up.ps1
```

Open <http://localhost:8080> and select `PF-DEMO000003`. Explain that the UI and
API are one workload while delivery execution is asynchronous.

## 3. Create and advance a parcel

Create a fictional parcel in the UI. Select **Advance delivery** and show:

1. the API accepts an idempotent command;
2. the outbox publishes it;
3. the worker applies one state transition;
4. polling reveals the new timeline event.

Repeat the same command through the smoke client to demonstrate that duplicate
delivery does not duplicate the transition.

## 4. Add proof of delivery

Use a delivered demo parcel to upload the repository's fixed proof fixture.
Download it again and compare the checksum and content type.

## 5. Run the complete smoke check

```powershell
.\scripts\local\smoke.ps1
```

The command verifies health, deterministic seed data, creation, asynchronous
progression, duplicate idempotency, and proof storage.

## 6. Compare platforms

Generate and inspect Compose and Kubernetes output:

```powershell
.\scripts\local\generate.ps1
.\scripts\local\kind-generate.ps1
```

Explain that the Score files did not change. Local provisioners created
PostgreSQL, RabbitMQ, and Azurite; the Azure profile attaches PostgreSQL,
Service Bus, and Blob Storage.

## 7. Show Azure

Run the same smoke client through a local port-forward to AKS:

```powershell
.\scripts\azure\Invoke-Smoke.ps1
```

Show correlated API/worker log records, the Service Bus queue, private proof
container, and PostgreSQL persistence after restarting an application pod.

## 8. End with ownership and cleanup

Review `docs/score.md`, emphasizing the developer/platform contract. Then show
the deployment-stack teardown command and current cost controls. Do not leave a
public endpoint or idle cloud environment running after the demonstration.
