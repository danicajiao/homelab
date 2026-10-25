# Cove backend services

Manifests for the [Cove iOS app](https://github.com/danicajiao/cove)'s self-hosted backend, currently being migrated off Firebase per the [Phase 0 epic](https://github.com/danicajiao/cove/issues/208).

## Status

**Phases 1–3 deployed** to `cove-staging` and `cove-prod` behind the Cloudflare Tunnel. Phase 0 stood up the platform (Argo CD, External Secrets Operator, CloudNativePG, Garage, observability, Cloudflare Tunnel) and the staging/prod namespaces.

| Phase | What lands here |
|---|---|
| Phase 0 | Empty `cove-staging` / `cove-prod` namespaces, Argo CD overlay scaffolding |
| Phase 1 | `cove-api` gateway (Deployment, Service, NetworkPolicy, ExternalSecret) |
| Phase 2 | Media service (`cove-media`, then named `cove-image`) + imgproxy |
| Phase 3 | `cove-catalog`, `cove-directory` (split from `cove-item` in [danicajiao/cove#413](https://github.com/danicajiao/cove/issues/413)), `cove-user`, and the `cove-db` CNPG `Cluster` |

## Services

Only `cove-api` is public. Everything else is a ClusterIP Service that `cove-api` reaches by in-cluster DNS, forwarding the verified Firebase UID as `X-Cove-Uid`.

| Service | Routes (via `cove-api`) | Postgres schema | Secrets |
|---|---|---|---|
| `cove-api` | public gateway; `/i/*` → imgproxy | — | Firebase service account |
| `cove-media` | `/images`, `/images/*` | — | imgproxy signing keys, Garage `cove-media` creds |
| `cove-catalog` | `/discovery`, `/categories`, `/items/*` | `catalog` | `cove-db-app`, imgproxy signing keys |
| `cove-directory` | `/producers/*`, `/places/*` | `directory` | `cove-db-app`, imgproxy signing keys |
| `cove-user` | `/users/*`, `/recommendations/*` | `profile` | `cove-db-app` |
| `imgproxy` | — | — | imgproxy signing keys, Garage `cove-media` creds |

The services connect as the CNPG `app` user for now. `cove-db/cluster.yaml` bootstraps one role per service (`cove_catalog`, `cove_directory`, `cove_user`) for when role separation is enforced. Bootstrap SQL only runs when a cluster is created, so existing clusters get role changes by hand.

## Layout

```
apps/cove/
├── base/                    # shared manifests
│   ├── gar-pull-secret.yaml # ExternalSecret for GAR image pulls
│   ├── cove-api/            # Deployment, Service, NetworkPolicy, ExternalSecret
│   ├── cove-media/          # Deployment, Service
│   ├── cove-catalog/        # Deployment, Service
│   ├── cove-directory/      # Deployment, Service
│   ├── cove-user/           # Deployment, Service
│   ├── imgproxy/            # Deployment, Service, ExternalSecrets
│   └── cove-db/             # CNPG Cluster, ObjectStore, ScheduledBackup, ExternalSecret
└── overlays/
    ├── staging/             # → cove-staging namespace; pins every service's image tag
    └── prod/                # → cove-prod namespace; pins tags, patches prod URLs
```

The `cove-staging` and `cove-prod` Argo CD Applications (in [`argocd/`](../../argocd/)) point at these overlays and auto-sync from `main` with pruning. Each overlay pins one `sha-*` tag per service via the Kustomize `images:` transformer, so the base stays environment-agnostic. Cove's CI opens a PR here that bumps every tag, and fails if an overlay is missing an `images:` entry for a service. Add a new service to `base/` and to both overlays' `images:` in the same PR.

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
