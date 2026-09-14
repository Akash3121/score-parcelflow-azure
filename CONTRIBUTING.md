# Contributing

Thank you for improving ParcelFlow.

## Development

1. Create a branch from `main`.
2. Start Docker Desktop.
3. Run `.\scripts\local\preflight.ps1`.
4. Run Go formatting, tests, and static checks.
5. Generate the local environment with Score and run the smoke test.
6. Update documentation when behavior or platform contracts change.

Do not commit generated Score state, generated Compose/Kubernetes manifests,
credentials, kubeconfig files, or deployment outputs.

## Design expectations

- Keep `deploy/score/*.score.yaml` platform-neutral.
- Put local and Azure resource behavior in provisioners.
- Preserve idempotency for every externally retried command.
- Keep seed and test data fictional and deterministic.
- Prefer small, reviewable changes with explicit error handling.
- Record significant architectural changes in `docs/adr`.

## Pull requests

Describe the user-visible behavior, Score/platform impact, tests performed, and
any cost or security implications. Azure deployment workflows must remain
manual and must not execute untrusted fork code.
