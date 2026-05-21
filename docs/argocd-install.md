# Argo CD Install Runbook

> One-time install of [Argo CD](https://argo-cd.readthedocs.io/) on the homelab K3s cluster. After this runbook, the cluster is GitOps-managed: every change to `homelab/` on `main` reconciles automatically.

## What this sets up

- Argo CD running in the `argocd` namespace
- An **app-of-apps** root Application that manages every other Application from `homelab/argocd/`
- Argo CD **self-management** — Argo CD reconciles its own install from `homelab/infra/argocd/`, so future version bumps happen via PR
- Empty `cove-staging` and `cove-prod` Applications wired up against `homelab/apps/cove/overlays/{staging,prod}/`, ready to absorb services as Phase 1+ sub-issues land

## Prerequisites

- K3s cluster reachable via `kubectl`. Verify: `kubectl cluster-info`
- `kubectl` >= 1.27 (for stable Kustomize support via `-k`)
- This `homelab` repo must be **readable by Argo CD without credentials**. Either:
    - The repo is **public** (recommended for homelab setups — manifests describe what runs, never what the secrets are; real secrets live in External Secrets Operator pulling from GCP Secret Manager). Make it public with: `gh repo edit danicajiao/homelab --visibility public --accept-visibility-change-consequences`.
    - Or add a GitHub PAT as a `repository`-typed Secret in the `argocd` namespace ([Argo CD docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories)). Most homelab projects skip this and go public.

  Without one of these, root sync fails with `failed to list refs: authentication required: Repository not found`.
- The bootstrap manifests in this repo (`infra/argocd/`, `argocd/`, `apps/cove/`) must be on the branch `root.yaml` watches. Default `targetRevision` is `main`, so **merge the bootstrap PR before applying `root.yaml`** in Step 2 — otherwise root will sync `Unknown` because the path doesn't exist on `main` yet.
- A few minutes — the install pulls roughly a dozen container images on first sync

## Repo layout (relevant pieces)

```
homelab/
├── infra/
│   └── argocd/
│       ├── kustomization.yaml          # references upstream install.yaml @ pinned version
│       └── namespace.yaml              # creates the argocd namespace
├── argocd/
│   ├── kustomization.yaml              # lists every child Application
│   ├── root.yaml                       # the app-of-apps root (apply once)
│   ├── argocd-self.yaml                # Argo CD managing its own install
│   ├── apps-cove-staging.yaml          # → apps/cove/overlays/staging
│   └── apps-cove-prod.yaml             # → apps/cove/overlays/prod
└── apps/cove/{base,overlays/{staging,prod}}/
    └── kustomization.yaml              # empty placeholders until Phase 1+
```

---

## Step 1 — Initial bootstrap

Apply the Kustomize tree directly. This installs Argo CD imperatively, the same way `argocd-self` will manage it from this point forward.

```bash
kubectl apply -k infra/argocd --server-side --force-conflicts
```

`--server-side` is **required** here. Argo CD's `applicationsets.argoproj.io` CRD has annotations larger than the 262KB limit on client-side apply, and the install will fail with `metadata.annotations: Too long` if you omit it. Server-side apply handles the large CRD correctly and is also closer to how Argo CD itself reconciles resources, so subsequent self-management has no field-ownership churn.

`--force-conflicts` is harmless on a clean install and lets you re-run idempotently if a previous attempt partially applied client-side.

Expected output: a long list of `serverside-applied` lines for CRDs, ServiceAccounts, ClusterRoles, Deployments, etc.

Wait for pods to be ready:

```bash
kubectl -n argocd get pods -w
```

You should end up with `Running` and `Ready 1/1` for `argocd-server`, `argocd-repo-server`, `argocd-application-controller`, `argocd-applicationset-controller`, `argocd-notifications-controller`, `argocd-redis`, and `argocd-dex-server`. Use Ctrl-C once everything is ready.

## Step 2 — Apply the app-of-apps root

> **Precondition:** the bootstrap PR adding `infra/argocd/`, `argocd/`, and `apps/cove/` must already be merged into `main`. `root.yaml` has `targetRevision: main`, so applying it before the manifests are on `main` will leave root in `Unknown` state.

```bash
kubectl apply -f argocd/root.yaml
```

This is the **only Application you ever apply by hand**. It creates child Applications by reconciling against `homelab/argocd/`, and one of those children (`argocd-self`) takes over reconciling Argo CD itself.

## Step 3 — Verify

List Applications:

```bash
kubectl -n argocd get applications
```

You should see:

```
NAME            SYNC STATUS   HEALTH STATUS
root            Synced        Healthy
argocd          Synced        Healthy
cove-staging    Synced        Healthy
cove-prod       Synced        Healthy
```

`cove-staging` and `cove-prod` are healthy because their overlays are empty — there's nothing for Argo CD to fail to deploy yet. That's intentional for this phase.

If anything is `OutOfSync`, run `argocd app get <name>` (after Step 4) for diagnostics.

---

## Step 4 — Access the UI and CLI

### Install the `argocd` CLI

```bash
brew install argocd
```

Or grab a release directly: <https://github.com/argoproj/argo-cd/releases>.

### Port-forward the API server

In one terminal, leave this running:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

The UI is now at <https://localhost:8080>. Self-signed cert — accept the warning.

### Initial admin password

The first install generates a random password stored in a Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d
echo
```

Username: `admin`.

Log in via CLI:

```bash
argocd login localhost:8080 --username admin --insecure
# Paste the password when prompted.
```

`--insecure` skips cert verification (needed because the API server uses a self-signed cert by default; expose with proper TLS later via Cloudflare Tunnel).

### Change the admin password

The auto-generated password is meant to be rotated immediately:

```bash
argocd account update-password
```

After rotating, you can delete the bootstrap secret:

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

---

## Day-2 operations

### View an Application

```bash
argocd app list
argocd app get root
argocd app get argocd
```

The `kubectl -n argocd get applications` form works too if you don't want to log in to the CLI.

### Force a sync

Argo CD auto-syncs every 3 minutes by default, plus on every git push that touches a watched path. To trigger immediately:

```bash
argocd app sync <app-name>
```

### Bump the Argo CD version

1. Edit `infra/argocd/kustomization.yaml` and change the pinned tag in the upstream URL.
2. Verify the rendered output looks sane: `kubectl kustomize infra/argocd | head -50`
3. Open a PR. Once merged, `argocd-self` reconciles the new version into the cluster.
4. Watch `kubectl -n argocd get pods -w` during the rollout.

If something goes catastrophically wrong, revert the PR — Argo CD will reconcile back.

### Adding a new platform operator (#211–#216)

For each future operator (External Secrets Operator, CloudNativePG, Garage, kube-prometheus-stack, Loki, Cloudflare Tunnel):

1. Add manifests under `infra/<operator-name>/` with a `kustomization.yaml`.
2. Add a new Application manifest at `argocd/<operator-name>.yaml` pointing at that directory.
3. Add the new Application to `argocd/kustomization.yaml`.
4. Open a PR. Once merged, the root Application creates the new child Application, which deploys the operator.

That's the entire add-an-operator flow from now on. No more `kubectl apply` outside of the initial bootstrap.

### Adding a Cove service (Phase 1+)

1. Add manifests under `apps/cove/base/<service>/` with their own `kustomization.yaml`.
2. Reference them from `apps/cove/base/kustomization.yaml`.
3. Add per-environment patches under `apps/cove/overlays/{staging,prod}/` if needed.
4. Open a PR. The `cove-staging` and `cove-prod` Applications already watch the overlay paths — they'll pick up the new resources automatically.

---

## How self-management works

After Step 2:

- `root` Application watches `homelab/argocd/` and creates `argocd-self`, `cove-staging`, `cove-prod` Applications.
- `argocd-self` watches `homelab/infra/argocd/` and reconciles the Argo CD install itself against the live cluster.
- The initial `kubectl apply -k infra/argocd` manifests **match** what `argocd-self` produces, so Argo CD recognizes them as already-managed and reports `Synced` immediately.

Self-management uses `prune: false` on purpose. If a resource disappears from `infra/argocd/kustomization.yaml`, Argo CD will **not** auto-delete it from the cluster — accidentally pruning a CRD or the application controller would brick the cluster. Pruning happens manually when you genuinely want to remove something:

```bash
argocd app sync argocd --prune
```

---

## SSO / login plan (deferred)

For now, login is admin/password through the port-forwarded UI. That's fine for solo use.

When team members or external auth become relevant:

- **GitHub OAuth via dex** (built into Argo CD) is the standard path. Configure in `argocd-cm` ConfigMap under `infra/argocd/`.
- Or **OIDC against Google Workspace** if a Google account becomes the canonical identity.

Either way, the change is a few extra fields in the Argo CD `ConfigMap` — no infrastructure churn.

This is a Phase 5+ concern.

---

## Troubleshooting

### `metadata.annotations: Too long: may not be more than 262144 bytes`

You ran the bootstrap without `--server-side`. Re-run with the correct flags:

```bash
kubectl apply -k infra/argocd --server-side --force-conflicts
```

The Argo CD `applicationsets.argoproj.io` CRD's `last-applied-configuration` annotation exceeds Kubernetes' client-side apply limit. Server-side apply doesn't use that annotation. See the [Argo CD install docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/) for context.

### Some resources fail to apply on first bootstrap

If a transient error leaves the install in a partial state, re-run idempotently:

```bash
kubectl apply -k infra/argocd --server-side --force-conflicts
```

### `root` is stuck `Unknown` with `failed to list refs: authentication required: Repository not found`

The repo isn't reachable by Argo CD without credentials. Either make `homelab` public:

```bash
gh repo edit danicajiao/homelab --visibility public --accept-visibility-change-consequences
```

Or add a GitHub PAT — see Prerequisites above for the link to Argo CD's docs on private-repo credentials.

After fixing, force a refresh:

```bash
kubectl -n argocd annotate application root \
    argocd.argoproj.io/refresh=hard --overwrite
```

### `root` is `Unknown` with a "path not found" or empty-manifest error

The bootstrap manifests aren't on the branch `root.yaml` watches. If you applied `root.yaml` from a feature branch but the manifests aren't yet merged to `main`, root has nothing to reconcile against. Merge the bootstrap PR, then refresh:

```bash
kubectl -n argocd annotate application root \
    argocd.argoproj.io/refresh=hard --overwrite
```

### `argocd-server` is `CrashLoopBackOff`

Most common cause: insufficient resources on the node. Check:

```bash
kubectl -n argocd describe pod -l app.kubernetes.io/name=argocd-server
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-server --tail=100
```

The Ryzen 9600X / 64GB node has plenty of headroom; if you see OOM, something else is consuming memory.

### `root` Application stuck `OutOfSync`

```bash
argocd app diff root
```

Shows what Argo CD thinks should change. Common cause: the kustomization references a file that's not committed and pushed to the branch Argo CD is watching (`main`).

### Argo CD lost track of itself

If you blow away the `argocd-self` Application or it gets into a weird state, you can always re-run the bootstrap:

```bash
kubectl apply -k infra/argocd
kubectl apply -f argocd/root.yaml
```

The bootstrap is idempotent.

---

## What's next

All Phase 0 operators below are now installed — each followed the **adding a new platform operator** pattern in this doc. Two swapped implementations during bootstrap: MinIO → Garage (see [garage-install.md](garage-install.md)) and Promtail → Grafana Alloy (see [loki-install.md](loki-install.md)).

- [danicajiao/cove#211](https://github.com/danicajiao/cove/issues/211) External Secrets Operator
- [danicajiao/cove#212](https://github.com/danicajiao/cove/issues/212) CloudNativePG
- [danicajiao/cove#213](https://github.com/danicajiao/cove/issues/213) Object storage (shipped as Garage, not MinIO)
- [danicajiao/cove#214](https://github.com/danicajiao/cove/issues/214) kube-prometheus-stack
- [danicajiao/cove#215](https://github.com/danicajiao/cove/issues/215) Loki (log collector shipped as Alloy, not Promtail)
- [danicajiao/cove#216](https://github.com/danicajiao/cove/issues/216) Cloudflare Tunnel
