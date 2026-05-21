# External Secrets Operator Install Runbook

> One-time install of [External Secrets Operator](https://external-secrets.io/) (ESO) on the homelab K3s cluster, wired to **two** GCP Secret Manager backends — project `cove-6a685` for cove-side workloads and project `homelab-495921` for homelab-only workloads. After this runbook, every service can declare an `ExternalSecret` against the right store and have its secrets materialize as a normal K8s `Secret`.

## What this sets up

- ESO running in the `external-secrets` namespace, installed via the upstream Helm chart at a pinned version
- A `ClusterSecretStore` named `gcp-cove` pointing at GCP project `cove-6a685`, backing cove-side workloads (Garage bucket creds consumed by cove-image, CNPG-managed cove databases, etc.)
- A `ClusterSecretStore` named `gcp-homelab` pointing at GCP project `homelab-495921`, backing homelab-only workloads (Minecraft today; Cloudflare Tunnel + Grafana when those land)
- Two bootstrap K8s `Secret`s holding each project's service account JSON key — `gcp-sm-credentials` (cove) and `gcp-homelab-credentials` (homelab). Both are created out-of-band by this runbook, **not** committed to git
- A smoke-test `ExternalSecret` (against `gcp-cove`) that pulls a throwaway value from GCP Secret Manager to prove the wiring end-to-end

All of this is reconciled by Argo CD via the `external-secrets` Application at `argocd/external-secrets.yaml`. The Application is a two-source manifest: source 1 is the Helm chart, source 2 is `infra/external-secrets/` (namespace + both ClusterSecretStores + smoke test).

## Which project does my secret belong in?

The rule is **consumer-owns**: a secret lives in the GCP project of the *workload that consumes it*, not the project of whatever service issued the credential.

| Example secret | Consumer | Project | Store |
|---|---|---|---|
| `garage-cove-media-access-key` (S3 key for the `cove-media` bucket) | cove-image, CNPG `Cluster` resources for cove DBs | `cove-6a685` | `gcp-cove` |
| `garage-postgres-backups-*-key` | CNPG cluster running cove's database | `cove-6a685` | `gcp-cove` |
| `cove-api-firebase-service-account` (Firebase Admin SDK creds for cove-api) | `cove-api` in the `cove-staging` / `cove-prod` namespaces | `cove-6a685` | `gcp-cove` |
| `minecraft-curseforge-api-key` | Minecraft server in the `gaming` namespace | `homelab-495921` | `gcp-homelab` |
| Cloudflare Tunnel token | `cloudflared` in the `cloudflare-tunnel` namespace | `homelab-495921` | `gcp-homelab` |
| Grafana admin password | Grafana in the `monitoring` namespace | `homelab-495921` | `gcp-homelab` |

The Garage access keys are an instructive case: Garage itself runs in the homelab cluster, but the keys are *consumed by cove apps* — so they belong in the cove project. A leaked cove SA exposes the buckets that cove uses; a leaked homelab SA exposes Minecraft's CF key. Blast radius stays scoped to a single product surface.

Why we care: it caps blast radius (a compromised SA in one project can't read the other's secrets), keeps IAM clarity (cove's project may eventually grant Secret Manager access to CI / prod runtime SAs that should never see Minecraft's keys), and treats `cove-6a685` as a Firebase project that shouldn't accrete unrelated homelab secrets.

## Prerequisites

- Argo CD already installed and the root app-of-apps reconciling. If it isn't, do that first via `docs/argocd-install.md`.
- `kubectl` pointed at the K3s cluster
- `gcloud` authenticated and able to switch between both projects:
    - `gcloud config configurations create cove-6a685 --project cove-6a685` (or `gcloud config set project cove-6a685`)
    - `gcloud config configurations create homelab-495921 --project homelab-495921`
- Owner or `roles/iam.serviceAccountAdmin` + `roles/secretmanager.admin` on **both** projects — needed to create the SAs and grant them Secret Manager access. Each project's setup is independent.

## Repo layout (relevant pieces)

```
homelab/
├── infra/
│   └── external-secrets/
│       ├── kustomization.yaml                  # namespace + CRs only
│       ├── namespace.yaml
│       ├── cluster-secret-store-cove.yaml      # gcp-cove → cove-6a685
│       ├── cluster-secret-store-homelab.yaml   # gcp-homelab → homelab-495921
│       └── smoke-test.yaml                     # eso-smoke-test ExternalSecret (uses gcp-cove)
└── argocd/
    └── external-secrets.yaml                   # two-source Application (chart + this dir)
```

The Helm chart itself is **not** vendored; Argo CD pulls it from `https://charts.external-secrets.io` at the version pinned in `argocd/external-secrets.yaml`. Bumping the chart is a one-line edit in that file.

---

## Step 1 — Enable Secret Manager + create per-project service accounts

Each `ClusterSecretStore` authenticates to its project as a dedicated GCP service account. **Repeat this step once per project.** The commands below show the cove project; rerun the same pattern for `homelab-495921`.

Enable the Secret Manager API (no-op if it's already enabled):

```bash
gcloud services enable secretmanager.googleapis.com --project cove-6a685
```

Create the service account:

```bash
gcloud iam service-accounts create external-secrets-operator \
    --project cove-6a685 \
    --display-name "External Secrets Operator (homelab K3s, cove project)"
```

Grant it read access to every secret in the project:

```bash
gcloud projects add-iam-policy-binding cove-6a685 \
    --member="serviceAccount:external-secrets-operator@cove-6a685.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
```

> If you want stricter scoping later, swap the project-level binding for per-secret bindings via `gcloud secrets add-iam-policy-binding`. `secretAccessor` at the project level is fine for Phase 0.

**Repeat the same three commands for `homelab-495921`** — same SA name (`external-secrets-operator`), same role, just substituting the project ID. The two SAs are unrelated identities living in unrelated projects; reusing the name is purely cosmetic.

## Step 2 — Create + download a JSON key per project

```bash
gcloud iam service-accounts keys create ./cove-key.json \
    --iam-account external-secrets-operator@cove-6a685.iam.gserviceaccount.com

gcloud iam service-accounts keys create ./homelab-key.json \
    --iam-account external-secrets-operator@homelab-495921.iam.gserviceaccount.com
```

The two JSON files are now sitting in your working directory. **Do not commit them.** Treat them like passwords.

## Step 3 — Bootstrap the credentials Secrets

Each ClusterSecretStore references a K8s `Secret` in the `external-secrets` namespace:

- `gcp-cove` → `gcp-sm-credentials`, key `key.json`
- `gcp-homelab` → `gcp-homelab-credentials`, key `key.json`

Both must exist before Argo CD reconciles, otherwise the ClusterSecretStores will report `SecretSyncedError: secret not found`.

> The cove-side bootstrap Secret is named `gcp-sm-credentials` for historical reasons (it predates the project split). Renaming to `gcp-cove-credentials` for symmetry is a small low-priority follow-up.

The namespace must exist first. Easiest path: apply just the namespace manifest from this repo:

```bash
kubectl apply -f infra/external-secrets/namespace.yaml
```

Then load both JSON keys:

```bash
kubectl create secret generic gcp-sm-credentials \
    --from-file=key.json=./cove-key.json \
    -n external-secrets

kubectl create secret generic gcp-homelab-credentials \
    --from-file=key.json=./homelab-key.json \
    -n external-secrets
```

Verify:

```bash
kubectl -n external-secrets get secret gcp-sm-credentials \
    -o jsonpath='{.data.key\.json}' | base64 -d | jq .client_email
# → "external-secrets-operator@cove-6a685.iam.gserviceaccount.com"

kubectl -n external-secrets get secret gcp-homelab-credentials \
    -o jsonpath='{.data.key\.json}' | base64 -d | jq .client_email
# → "external-secrets-operator@homelab-495921.iam.gserviceaccount.com"
```

Once verified, **delete the local JSON files**:

```bash
rm ./cove-key.json ./homelab-key.json
```

The Secrets in the cluster are now the only copies. (See [Rotating an SA key](#rotating-an-sa-key) below for replacement.)

## Step 4 — Merge the PR

Merge the PR that adds `infra/external-secrets/` and `argocd/external-secrets.yaml` into `main`. Argo CD's root Application watches `argocd/`, so within ~3 minutes (or immediately if you `argocd app sync root`) the `external-secrets` child Application appears and starts reconciling.

You can also force it:

```bash
kubectl -n argocd annotate application root \
    argocd.argoproj.io/refresh=hard --overwrite
```

## Step 5 — Verify

List Applications:

```bash
kubectl -n argocd get applications
```

`external-secrets` should be `Synced` and `Healthy`. Then check the operator pods:

```bash
kubectl -n external-secrets get pods
```

Expected (names will have hash suffixes):

```
NAME                                                 READY   STATUS    RESTARTS
external-secrets-7b8c9d4f5b-xxxxx                    1/1     Running   0
external-secrets-cert-controller-6b4c8d7f9c-xxxxx    1/1     Running   0
external-secrets-webhook-5d6f8b7c9d-xxxxx            1/1     Running   0
```

Confirm both `ClusterSecretStore`s are valid (each one talks to its GCP project on creation):

```bash
kubectl get clustersecretstore gcp-cove gcp-homelab
```

`STATUS` should be `Valid` for both. If either is `Invalid`, run `kubectl describe clustersecretstore <name>` — the most common cause is a typo in the bootstrap Secret or a missing IAM binding in that store's project.

## Step 6 — Smoke test

Create a throwaway secret in the cove GCP project (the smoke test exercises the `gcp-cove` store):

```bash
echo -n "hello-from-gcp" | gcloud secrets create eso-smoke-test \
    --project cove-6a685 \
    --data-file=- \
    --replication-policy=automatic
```

The smoke-test `ExternalSecret` (`infra/external-secrets/smoke-test.yaml`) is already in the cluster from Step 4. It refreshes every hour, but you can force it now:

```bash
kubectl -n external-secrets annotate externalsecret eso-smoke-test \
    force-sync=$(date +%s) --overwrite
```

Watch it materialize:

```bash
kubectl -n external-secrets get externalsecret eso-smoke-test
kubectl -n external-secrets get secret eso-smoke-test -o yaml
```

The K8s `Secret` should have a `data.value` field whose base64-decoded value is `hello-from-gcp`:

```bash
kubectl -n external-secrets get secret eso-smoke-test \
    -o jsonpath='{.data.value}' | base64 -d
# → hello-from-gcp
```

The `gcp-homelab` store doesn't get its own dedicated smoke test — the Minecraft `minecraft-curseforge-key` ExternalSecret exercises it end-to-end on every refresh, which is sufficient.

Once verified, you can either leave the smoke test in place (cheap, ~zero overhead) or remove it. To remove:

1. Delete `infra/external-secrets/smoke-test.yaml` and the line referencing it in `kustomization.yaml`, open a PR.
2. After merge, delete the GCP-side secret: `gcloud secrets delete eso-smoke-test --project cove-6a685`.

The current default is to **leave it in tree** so Argo CD always has something concrete to reconcile against.

> **Historical note:** the cove-side store was originally named `gcp-secret-manager`. It was renamed to `gcp-cove` in [#14](https://github.com/danicajiao/homelab/issues/14) once the sibling `gcp-homelab` store landed, because the original name was ambiguous in a two-project world. If you see `gcp-secret-manager` in older comments / docs / `kubectl get` output during the transition window, treat it as a synonym for `gcp-cove`.

---

## How to add a new secret going forward

1. Pick the right project using the [consumer-owns rule](#which-project-does-my-secret-belong-in). If the consumer is a cove app, use `cove-6a685`; if it's a homelab-only workload, use `homelab-495921`.
2. Create the secret in that project's GCP Secret Manager:
   ```bash
   echo -n "<value>" | gcloud secrets create <secret-name> \
       --project <cove-6a685|homelab-495921> --data-file=- --replication-policy=automatic
   ```
3. In your service overlay, add an `ExternalSecret` referencing the matching store (`gcp-cove` or `gcp-homelab`):
   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
       name: <service>-config
       namespace: <consumer-namespace>
   spec:
       refreshInterval: 1h
       secretStoreRef:
           kind: ClusterSecretStore
           name: gcp-cove   # or gcp-homelab
       target:
           name: <service>-config
       data:
           - secretKey: <env-var-name>
             remoteRef:
                 key: <secret-name>
   ```
4. Reference the resulting K8s `Secret` from your Deployment via `envFrom` or a volume mount. Argo CD reconciles the `ExternalSecret`, ESO populates the `Secret`, the Deployment picks it up.

No more `kubectl create secret` outside of the one-time bootstrap step.

## How to add a third GCP project

If a future workload needs a third hard isolation boundary (say, a billing / financial integration that should be even further removed from cove and homelab), the pattern is:

1. Run Steps 1–3 against the new project (enable Secret Manager API, create `external-secrets-operator` SA, grant `roles/secretmanager.secretAccessor`, generate a JSON key, plant it in the cluster as `gcp-<name>-credentials`).
2. Add `infra/external-secrets/cluster-secret-store-<name>.yaml` mirroring the existing two — same shape, just substituting `projectID` and `auth.secretRef.secretAccessKeySecretRef.name`.
3. Wire it into `infra/external-secrets/kustomization.yaml` `resources:` list.
4. Update the consumer-owns table at the top of this doc with the new project + its scope.
5. Open a PR. Argo CD reconciles the new store; existing ExternalSecrets are untouched.

The pattern stays flat — there's no nesting of stores. Each project gets one store, named after the project, and consumers pick the right one.

---

## Rotating an SA key

Service account JSON keys should be rotated at least yearly, sooner if there's any chance of leakage. The flow is the same for both projects; substitute the SA email and bootstrap Secret name as appropriate.

For the **cove** SA:

1. Create a new key (the SA can hold up to 10 simultaneously):
   ```bash
   gcloud iam service-accounts keys create ./key.json \
       --iam-account external-secrets-operator@cove-6a685.iam.gserviceaccount.com
   ```
2. Replace the K8s Secret in place:
   ```bash
   kubectl create secret generic gcp-sm-credentials \
       --from-file=key.json=./key.json \
       -n external-secrets \
       --dry-run=client -o yaml | kubectl apply -f -
   ```
3. ESO re-reads the credential on the next refresh; force it sooner with:
   ```bash
   kubectl -n external-secrets rollout restart deployment external-secrets
   ```
4. Confirm an `ExternalSecret` still syncs (the smoke test above is the easiest probe).
5. List and delete the old key:
   ```bash
   gcloud iam service-accounts keys list \
       --iam-account external-secrets-operator@cove-6a685.iam.gserviceaccount.com
   gcloud iam service-accounts keys delete <old-key-id> \
       --iam-account external-secrets-operator@cove-6a685.iam.gserviceaccount.com
   ```
6. `rm ./key.json` locally.

For the **homelab** SA: same flow, substituting `homelab-495921` for the project, `external-secrets-operator@homelab-495921.iam.gserviceaccount.com` for the SA email, and `gcp-homelab-credentials` for the bootstrap Secret name. The Minecraft `minecraft-curseforge-key` ExternalSecret is the easiest probe to confirm sync after rotation.

---

## Troubleshooting

### `ClusterSecretStore` shows `Invalid`

```bash
kubectl describe clustersecretstore <gcp-cove|gcp-homelab>
```

Common causes:
- The bootstrap Secret (`gcp-sm-credentials` for cove, `gcp-homelab-credentials` for homelab) doesn't exist or is in the wrong namespace
- The JSON key isn't under the key `key.json`
- The service account is missing `roles/secretmanager.secretAccessor` in that project

### `ExternalSecret` shows `SecretSyncedError`

```bash
kubectl -n <ns> describe externalsecret <name>
```

Usually one of:
- The remote secret doesn't exist in the project the ExternalSecret's store points at — check the store name on the ExternalSecret and run `gcloud secrets list --project <matching-project>`
- The store name on the ExternalSecret is the wrong one (a homelab-consumer ExternalSecret pointing at `gcp-cove` will fail to find homelab-project secrets, and vice versa)
- The SA doesn't have access to that specific secret (rare with project-level binding, common if you scoped to per-secret bindings)
- The `remoteRef.key` typo'd

### ESO pods stuck `Pending`

Probably resource pressure on the node. The chart defaults are modest (~100m CPU, ~128Mi RAM per pod) so this is unlikely on the Ryzen 9600X / 64GB host, but check `kubectl describe pod` for the scheduler reason.

### Bumping the ESO chart version

1. Edit `targetRevision` in `argocd/external-secrets.yaml`.
2. Verify locally: `kubectl kustomize infra/external-secrets/ | head -50` (just to confirm the CRs still parse — the chart itself is rendered by Argo CD, not by kustomize).
3. Open a PR. Once merged, Argo CD reconciles the new chart version. Watch `kubectl -n external-secrets get pods -w` during the rollout.
4. If something goes wrong, revert the PR.

Latest releases: <https://github.com/external-secrets/external-secrets/releases>

---

## What's next

With ESO running and both stores wired, every Phase 0 operator and Phase 1+ Cove service can declare its secrets via `ExternalSecret` resources instead of any `kubectl create secret` ceremony. CloudNativePG (#212) is the first real cove-side consumer — its Postgres superuser password will live in `cove-6a685` and surface to the cluster via `gcp-cove`. Cloudflare Tunnel and Grafana, when they land, will use `gcp-homelab`.
