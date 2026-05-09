# CloudNativePG Operator Install Runbook

> One-time install of the [CloudNativePG](https://cloudnative-pg.io/) (CNPG) operator on the homelab K3s cluster. After this runbook, the cluster knows how to reconcile Postgres `Cluster` resources — but no actual Postgres instances exist yet. Those land in Phase 3.

## What this sets up

- CNPG operator running in the `cnpg-system` namespace, installed via the upstream Helm chart at a pinned version
- The full CNPG CRD set: `Cluster`, `Pooler`, `Backup`, `ScheduledBackup` (and a few internal ones — see Step 2)
- That's it. **No `Cluster` resources** are created in Phase 0. The smoke test is "operator pod healthy + CRDs registered."

All of this is reconciled by Argo CD via the `cnpg` Application at `argocd/cnpg.yaml`. The Application is single-source — just the Helm chart. When Phase 3 introduces the `cove-product` and `cove-user` `Cluster` resources, this will likely grow a second source pointing at `infra/cnpg/` (mirroring the ESO layout).

## Prerequisites

- Argo CD already installed and the root app-of-apps reconciling. If it isn't, do that first via `docs/argocd-install.md`.
- `kubectl` pointed at the K3s cluster

## Repo layout (relevant pieces)

```
homelab/
├── infra/
│   └── cnpg/
│       ├── kustomization.yaml          # namespace only (Phase 0)
│       └── namespace.yaml              # creates cnpg-system
└── argocd/
    └── cnpg.yaml                       # single-source Application (Helm chart)
```

The Helm chart itself is **not** vendored; Argo CD pulls it from `https://cloudnative-pg.github.io/charts` at the version pinned in `argocd/cnpg.yaml`. Bumping the chart is a one-line edit in that file (see [Bumping the chart](#bumping-the-chart) below).

---

## Step 1 — Merge the PR

Merge the PR that adds `infra/cnpg/` and `argocd/cnpg.yaml` into `main`. Argo CD's root Application watches `argocd/`, so within ~3 minutes (or immediately if you `argocd app sync root`) the `cnpg` child Application appears and starts reconciling.

You can also force it:

```bash
kubectl -n argocd annotate application root \
    argocd.argoproj.io/refresh=hard --overwrite
```

## Step 2 — Verify

Three checks. All three should pass before declaring Phase 0 done for CNPG.

**1. Argo CD Application is Synced/Healthy:**

```bash
kubectl -n argocd get application cnpg
```

Both `SYNC STATUS` and `HEALTH STATUS` should read `Synced` / `Healthy`. If it's stuck `Progressing` or `OutOfSync`, run `kubectl -n argocd describe application cnpg` and check the `conditions` block.

**2. Operator pod is Running:**

```bash
kubectl -n cnpg-system get pods
```

Expected (name will have a hash suffix):

```
NAME                                         READY   STATUS    RESTARTS
cnpg-cloudnative-pg-xxxxxxxxxx-xxxxx         1/1     Running   0
```

A single operator Deployment with one replica. If the pod is stuck `Pending` or `CrashLoopBackOff`, `kubectl -n cnpg-system describe pod` and `kubectl -n cnpg-system logs deployment/cnpg-cloudnative-pg` will tell you why.

**3. CRDs are registered:**

```bash
kubectl get crds | grep cnpg.io
```

Expected (chart 0.28.0 / appVersion 1.28.1):

```
backups.postgresql.cnpg.io
clusterimagecatalogs.postgresql.cnpg.io
clusters.postgresql.cnpg.io
databases.postgresql.cnpg.io
imagecatalogs.postgresql.cnpg.io
poolers.postgresql.cnpg.io
publications.postgresql.cnpg.io
scheduledbackups.postgresql.cnpg.io
subscriptions.postgresql.cnpg.io
```

The four named in the acceptance criteria (`Cluster`, `Pooler`, `Backup`, `ScheduledBackup`) must all appear. The others are internal CNPG resources that ride along with the chart and can be ignored at this stage.

## Step 3 — What's next

Phase 0 stops here. The actual Postgres clusters (`cove-product`, `cove-user`) are introduced in **Phase 3** — see issue [#208](https://github.com/danicajiao/cove/issues/208) for the epic and the full sequencing.

Until then, the operator sits idle: no `Cluster` CRs, no Postgres pods, no PVCs. That's intentional — Phase 0 only proves the operator + CRDs are healthy.

---

## Bumping the chart

1. Edit `targetRevision` in `argocd/cnpg.yaml`.
2. Verify locally that the namespace manifest still parses: `kubectl kustomize infra/cnpg/`. (The chart itself is rendered by Argo CD, not by kustomize — this only confirms the repo-managed pieces are still valid.)
3. Open a PR. Once merged, Argo CD reconciles the new chart version. Watch `kubectl -n cnpg-system get pods -w` during the rollout; the operator should roll cleanly without restart loops.
4. If something goes wrong, revert the PR.

Latest releases: <https://github.com/cloudnative-pg/charts/releases>
