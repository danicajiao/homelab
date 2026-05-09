# Cove backend services

Manifests for the [Cove iOS app](https://github.com/danicajiao/cove)'s self-hosted backend, currently being migrated off Firebase per the [Phase 0 epic](https://github.com/danicajiao/cove/issues/208).

## Status

**Phase 0 in progress** — cluster bootstrap, no Cove services running yet. Phase 0 stands up the platform (Argo CD, External Secrets Operator, CloudNativePG, Garage, observability, Cloudflare Tunnel) and the namespaces for staging/prod. Phase 1+ ship the actual services.

| Phase | What lands here |
|---|---|
| Phase 0 (now) | Empty `cove-staging` / `cove-prod` namespaces, Argo CD overlay scaffolding |
| Phase 1 | Gateway service |
| Phase 2 | Image service (`cove-image` + imgproxy) |
| Phase 3 | Product, User services + CNPG `Cluster` resources for their data |

## Layout

```
apps/cove/
├── base/                 # shared manifests (currently empty placeholder)
└── overlays/
    ├── staging/          # → reconciled into the cove-staging namespace
    └── prod/             # → reconciled into the cove-prod namespace
```

The `cove-staging` and `cove-prod` Argo CD Applications (in [`argocd/`](../../argocd/)) point at these overlays. As Phase 1+ services land, they get added in `base/` with environment-specific tweaks in each overlay.

## Infra this depends on

When services start landing, they'll lean on the operators installed in Phase 0:

| Service need | Operator | Runbook |
|---|---|---|
| Postgres database | CloudNativePG → declare a `Cluster` resource in the overlay | [docs/cnpg-install.md](../../docs/cnpg-install.md) |
| Object storage (images, backups) | Garage → use `AWS_*` env vars from synced K8s Secret | [docs/garage-install.md](../../docs/garage-install.md) |
| Service credentials at runtime | ESO → declare an `ExternalSecret` referencing GCP Secret Manager | [docs/external-secrets-install.md](../../docs/external-secrets-install.md) |
| External traffic | Cloudflare Tunnel (Phase 0, pending) | TBD |

## Related

- [Cove repo](https://github.com/danicajiao/cove)
- [Phase 0 epic — danicajiao/cove#208](https://github.com/danicajiao/cove/issues/208)
- Top-level [homelab README](../../README.md)
