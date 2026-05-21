# Cove backend services

Manifests for the [Cove iOS app](https://github.com/danicajiao/cove)'s self-hosted backend, currently being migrated off Firebase per the [Phase 0 epic](https://github.com/danicajiao/cove/issues/208).

## Status

**Phase 1 complete** — the `cove-api` gateway is deployed to `cove-staging` and `cove-prod` behind the Cloudflare Tunnel. Phase 0 stood up the platform (Argo CD, External Secrets Operator, CloudNativePG, Garage, observability, Cloudflare Tunnel) and the staging/prod namespaces. Phases 2–3 ship the remaining services.

| Phase | What lands here |
|---|---|
| Phase 0 | Empty `cove-staging` / `cove-prod` namespaces, Argo CD overlay scaffolding |
| Phase 1 (done) | `cove-api` gateway (Deployment, Service, NetworkPolicy, ExternalSecret) |
| Phase 2 | Image service (`cove-image` + imgproxy) |
| Phase 3 | Product, User services + CNPG `Cluster` resources for their data |

## Layout

```
apps/cove/
├── base/                 # shared manifests
│   ├── gar-pull-secret.yaml   # ExternalSecret for GAR image pulls
│   └── cove-api/              # Deployment, Service, NetworkPolicy, ExternalSecret
└── overlays/
    ├── staging/          # → cove-staging namespace; pins the staging cove-api image tag
    └── prod/             # → cove-prod namespace; pins the prod cove-api image tag
```

The `cove-staging` and `cove-prod` Argo CD Applications (in [`argocd/`](../../argocd/)) point at these overlays. Each overlay pins its own `sha-*` image tag for `cove-api` via the Kustomize `images:` transformer so the base stays environment-agnostic. As Phase 2+ services land, they get added in `base/` with environment-specific tweaks in each overlay.

## Infra this depends on

`cove-api` already leans on the operators installed in Phase 0, and later services add more:

| Service need | Operator | Runbook |
|---|---|---|
| External traffic | Cloudflare Tunnel routes `api.coveapp.dev` → the `cove-api` Service (in-cluster DNS) | — (manifests in [`infra/cloudflare-tunnel/`](../../infra/cloudflare-tunnel/)) |
| Service credentials at runtime | ESO → `ExternalSecret` syncs the Firebase service-account JSON from GCP Secret Manager | [docs/external-secrets-install.md](../../docs/external-secrets-install.md) |
| Object storage (images, backups) | Garage → use `AWS_*` env vars from synced K8s Secret (Phase 2+) | [docs/garage-install.md](../../docs/garage-install.md) |
| Postgres database | CloudNativePG → declare a `Cluster` resource in the overlay (Phase 3) | [docs/cnpg-install.md](../../docs/cnpg-install.md) |

## Related

- [Cove repo](https://github.com/danicajiao/cove)
- [Phase 0 epic — danicajiao/cove#208](https://github.com/danicajiao/cove/issues/208)
- Top-level [homelab README](../../README.md)
