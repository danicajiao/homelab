# External Secrets Operator Install Runbook

> One-time install of [External Secrets Operator](https://external-secrets.io/) (ESO) on the homelab K3s cluster, wired to **GCP Secret Manager** in project `cove-6a685`. After this runbook, every service can declare an `ExternalSecret` and have its secrets materialize as a normal K8s `Secret`.

## What this sets up

- ESO running in the `external-secrets` namespace, installed via the upstream Helm chart at a pinned version
- A `ClusterSecretStore` named `gcp-secret-manager` that authenticates to GCP using a long-lived service account JSON key
- A bootstrap K8s `Secret` (`gcp-sm-credentials`) holding that JSON key — created out-of-band by this runbook, **not** committed to git
- A smoke-test `ExternalSecret` that pulls a throwaway value from GCP Secret Manager to prove the wiring end-to-end

All of this is reconciled by Argo CD via the `external-secrets` Application at `argocd/external-secrets.yaml`. The Application is a two-source manifest: source 1 is the Helm chart, source 2 is `infra/external-secrets/` (namespace + ClusterSecretStore + smoke test).

## Prerequisites

- Argo CD already installed and the root app-of-apps reconciling. If it isn't, do that first via `docs/argocd-install.md`.
- `kubectl` pointed at the K3s cluster
- `gcloud` authenticated against the `cove-6a685` GCP project: `gcloud config set project cove-6a685`
- Owner or `roles/iam.serviceAccountAdmin` + `roles/secretmanager.admin` on the project — needed to create the SA and grant it Secret Manager access

## Repo layout (relevant pieces)

```
homelab/
├── infra/
│   └── external-secrets/
│       ├── kustomization.yaml          # namespace + CRs only
│       ├── namespace.yaml
│       ├── cluster-secret-store.yaml   # gcp-secret-manager ClusterSecretStore
│       └── smoke-test.yaml             # eso-smoke-test ExternalSecret
└── argocd/
    └── external-secrets.yaml           # two-source Application (chart + this dir)
```

The Helm chart itself is **not** vendored; Argo CD pulls it from `https://charts.external-secrets.io` at the version pinned in `argocd/external-secrets.yaml`. Bumping the chart is a one-line edit in that file.

---

## Step 1 — Create the GCP service account

ESO authenticates to Secret Manager as a dedicated service account. Create it once:

```bash
gcloud iam service-accounts create external-secrets-operator \
    --project cove-6a685 \
    --display-name "External Secrets Operator (homelab K3s)"
```

Grant it read access to every secret in the project:

```bash
gcloud projects add-iam-policy-binding cove-6a685 \
    --member="serviceAccount:external-secrets-operator@cove-6a685.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
```

> If you want stricter scoping later, swap the project-level binding for per-secret bindings via `gcloud secrets add-iam-policy-binding`. `secretAccessor` at the project level is fine for Phase 0.

Create and download a JSON key:

```bash
gcloud iam service-accounts keys create ./key.json \
    --iam-account external-secrets-operator@cove-6a685.iam.gserviceaccount.com
```

The file `key.json` is now sitting in your working directory. **Do not commit it.** Treat it like a password.

## Step 2 — Bootstrap the credentials Secret

The `ClusterSecretStore` references a K8s `Secret` named `gcp-sm-credentials` in the `external-secrets` namespace, key `key.json`. Create it before Argo CD reconciles, otherwise the ClusterSecretStore will report `SecretSyncedError: secret not found`.

The namespace must exist first. Easiest path: apply just the namespace manifest from this repo:

```bash
kubectl apply -f infra/external-secrets/namespace.yaml
```

Then load the JSON key:

```bash
kubectl create secret generic gcp-sm-credentials \
    --from-file=key.json=./key.json \
    -n external-secrets
```

Verify:

```bash
kubectl -n external-secrets get secret gcp-sm-credentials \
    -o jsonpath='{.data.key\.json}' | base64 -d | jq .client_email
# → "external-secrets-operator@cove-6a685.iam.gserviceaccount.com"
```

Once verified, **delete the local `key.json`**:

```bash
rm ./key.json
```

The Secret in the cluster is now the only copy. (See [Rotating the SA key](#rotating-the-sa-key) below for replacement.)

## Step 3 — Merge the PR

Merge the PR that adds `infra/external-secrets/` and `argocd/external-secrets.yaml` into `main`. Argo CD's root Application watches `argocd/`, so within ~3 minutes (or immediately if you `argocd app sync root`) the `external-secrets` child Application appears and starts reconciling.

You can also force it:

```bash
kubectl -n argocd annotate application root \
    argocd.argoproj.io/refresh=hard --overwrite
```

## Step 4 — Verify

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

Confirm the `ClusterSecretStore` is valid (it talks to GCP on creation):

```bash
kubectl get clustersecretstore gcp-secret-manager
```

`STATUS` should be `Valid`. If it's `Invalid`, run `kubectl describe clustersecretstore gcp-secret-manager` — the most common cause is a typo in the bootstrap Secret or a missing IAM binding.

## Step 5 — Smoke test

Create a throwaway secret in GCP Secret Manager:

```bash
echo -n "hello-from-gcp" | gcloud secrets create eso-smoke-test \
    --project cove-6a685 \
    --data-file=- \
    --replication-policy=automatic
```

The smoke-test `ExternalSecret` (`infra/external-secrets/smoke-test.yaml`) is already in the cluster from Step 3. It refreshes every hour, but you can force it now:

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

Once verified, you can either leave the smoke test in place (cheap, ~zero overhead) or remove it. To remove:

1. Delete `infra/external-secrets/smoke-test.yaml` and the line referencing it in `kustomization.yaml`, open a PR.
2. After merge, delete the GCP-side secret: `gcloud secrets delete eso-smoke-test --project cove-6a685`.

The current default is to **leave it in tree** so Argo CD always has something concrete to reconcile against — flip that decision when a real ESO consumer (CloudNativePG, app config, etc.) lands.

---

## How to add a new secret going forward

1. Create the secret in GCP Secret Manager:
   ```bash
   echo -n "<value>" | gcloud secrets create <secret-name> \
       --project cove-6a685 --data-file=- --replication-policy=automatic
   ```
2. In your service overlay (e.g. `apps/cove/base/<service>/`), add an `ExternalSecret` referencing `gcp-secret-manager`:
   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
       name: <service>-config
       namespace: cove-staging
   spec:
       refreshInterval: 1h
       secretStoreRef:
           kind: ClusterSecretStore
           name: gcp-secret-manager
       target:
           name: <service>-config
       data:
           - secretKey: <env-var-name>
             remoteRef:
                 key: <secret-name>
   ```
3. Reference the resulting K8s `Secret` from your Deployment via `envFrom` or a volume mount. Argo CD reconciles the `ExternalSecret`, ESO populates the `Secret`, the Deployment picks it up.

No more `kubectl create secret` outside of the one-time bootstrap step.

---

## Rotating the SA key

Service account JSON keys should be rotated at least yearly, sooner if there's any chance of leakage.

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

---

## Troubleshooting

### `ClusterSecretStore` shows `Invalid`

```bash
kubectl describe clustersecretstore gcp-secret-manager
```

Common causes:
- The `gcp-sm-credentials` Secret doesn't exist or is in the wrong namespace
- The JSON key isn't under the key `key.json`
- The service account is missing `roles/secretmanager.secretAccessor`

### `ExternalSecret` shows `SecretSyncedError`

```bash
kubectl -n <ns> describe externalsecret <name>
```

Usually one of:
- The remote secret doesn't exist in GCP Secret Manager (`gcloud secrets list --project cove-6a685`)
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

With ESO running, the remaining Phase 0 operators (#212–#216) and Phase 1+ Cove services can declare their secrets via `ExternalSecret` resources instead of any `kubectl create secret` ceremony. CloudNativePG (#212) is the first real consumer — its Postgres superuser password will live in GCP Secret Manager and surface to the cluster via this store.
