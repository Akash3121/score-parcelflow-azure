# Security policy

## Supported versions

ParcelFlow is a demonstration repository. Security fixes are applied only to the
latest revision of the default branch.

## Reporting a vulnerability

Do not open a public issue containing exploit details, credentials, personal
data, or active Azure resource information. Use GitHub's private vulnerability
reporting feature for this repository.

Include the affected component, reproduction steps, expected impact, and any
suggested mitigation. Reports are acknowledged on a best-effort basis.

## Demo boundaries

ParcelFlow:

- uses fictional parcel and address data;
- has no customer authentication or tenant isolation;
- defaults to `kubectl port-forward` rather than public ingress;
- is not designed to process real delivery data;
- must not be exposed publicly without the controls described in
  [docs/security.md](docs/security.md).

Never commit Azure credentials, generated Score state, generated manifests,
kubeconfig files, database passwords, or storage keys.
