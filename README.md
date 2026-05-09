# homelab

GitOps repository for a single-node K3s homelab cluster, managed by [Argo CD](https://argo-cd.readthedocs.io/). Argo CD watches `main` and reconciles every change.

**Hardware:** AMD Ryzen 9600X · 64 GB RAM · K3s with `local-path` provisioner. Detail in [docs/node-setup.md](docs/node-setup.md).

---

## What runs here

| Track | What | Status | Details |
|---|---|---|---|
| `apps/cove/` | Cove iOS app's backend services | Phase 0 in progress (cluster bootstrap) | [apps/cove/README.md](apps/cove/README.md) |
| `apps/gaming/minecraft/` | Minecraft Fabric server (Homestead modpack, port 25565) | Running | [apps/gaming/minecraft/README.md](apps/gaming/minecraft/README.md) |

Plus the platform layer in `infra/` that everything else builds on (see "Operators" below).

---

## Repository layout

```
homelab/
├── apps/
│   ├── cove/                    # Cove backend (Phase 1+ services land here)
│   │   ├── base/
│   │   └── overlays/{staging,prod}/
│   └── gaming/minecraft/        # Homestead Fabric modpack
├── infra/
│   ├── argocd/                  # Argo CD itself (self-managed via app-of-apps)
│   ├── external-secrets/        # ESO config (ClusterSecretStore + smoke test)
│   ├── cnpg/                    # CloudNativePG operator (Phase 3 provisions clusters)
│   └── garage/                  # Garage S3-compatible object storage
├── argocd/                      # Argo CD Application manifests (the app-of-apps roots)
├── docs/                        # Operator runbooks
└── .github/workflows/           # PR validation + manual deploys
```

---

## How deploys work

GitOps via Argo CD. The default path is **PR → CI → merge → Argo CD reconciles**:

1. Open a PR with manifest changes
2. CI validates: `kubectl kustomize` renders cleanly, `kubeconform` schema-checks the rendered output
3. Merge to `main`
4. Argo CD picks it up within ~3 minutes (or click **Hard Refresh** in the UI to apply immediately)

Argo CD's root `Application` watches `argocd/` and creates child Applications for every operator and app track. Argo CD itself is self-managing — bumping its version is a PR like any other.

---

## Operators installed

Each operator has a runbook covering install, day-2 operations, and any manual bootstrap steps:

| Operator | Purpose | Runbook |
|---|---|---|
| Argo CD | GitOps reconciler | [docs/argocd-install.md](docs/argocd-install.md) |
| External Secrets Operator | Sync GCP Secret Manager → K8s Secrets | [docs/external-secrets-install.md](docs/external-secrets-install.md) |
| CloudNativePG (CNPG) | Postgres `Cluster` CRDs (clusters provisioned in Phase 3) | [docs/cnpg-install.md](docs/cnpg-install.md) |
| Garage | S3-compatible object storage (`images`, `postgres-backups`) | [docs/garage-install.md](docs/garage-install.md) |

Pending Phase 0: kube-prometheus-stack, Loki + Promtail, Cloudflare Tunnel.

---

## Secrets

All real secret values live in **GCP Secret Manager** (project `cove-6a685`). Nothing in `main` is ever a real secret value.

Flow:

1. The value gets created in GCP Secret Manager (`gcloud secrets create ...`)
2. An `ExternalSecret` manifest in this repo declares "materialize this in namespace X as K8s Secret Y"
3. ESO reconciles it on its refresh interval (default 1h; force-sync via annotation)

The one bootstrap exception: ESO needs GCP credentials to fetch other secrets, so its own GCP service account JSON key is planted manually as a K8s Secret. Detailed in [docs/external-secrets-install.md](docs/external-secrets-install.md).

`*.env` files, `secrets.yaml`, and downloaded SA keys are gitignored as belt-and-suspenders.

---

## More

- Hardware / network / SSH: [docs/node-setup.md](docs/node-setup.md)
- Common kubectl / k3s commands: [docs/commands.md](docs/commands.md)
