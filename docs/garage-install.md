# Garage Install Runbook

> One-time install of [Garage](https://garagehq.deuxfleurs.fr/) — an S3-compatible object store — on the homelab K3s cluster, plus the manual bootstrap that brings up the cluster layout, the `images` and `postgres-backups` buckets, and two scoped access key pairs stored in **GCP Secret Manager** (project `cove-6a685`). After this runbook, every service that needs S3 storage can declare an `ExternalSecret` against those keys and talk to `http://garage.garage.svc.cluster.local:3900` like any other S3 endpoint.

## What this sets up

- Garage running in the `garage` namespace as a single-replica StatefulSet, installed via the upstream Helm chart at a pinned git tag (the chart lives inside the Garage source repo at `script/helm/garage`, not in a Helm repo)
- PVC-backed persistence: 2Gi for metadata, 20Gi for object data, both on the K3s default `local-path` storage class
- A single-node cluster layout: replication factor 1, zone `dc1`
- Two buckets: `images` (product images for Phase 2 services + imgproxy source) and `postgres-backups` (CNPG backup destination, Phase 3)
- Two scoped access key pairs (`cove-images`, `cove-postgres-backups`) — each scoped read/write/owner to exactly one bucket
- Four GCP Secret Manager entries holding those key pairs:
    - `garage-images-access-key`, `garage-images-secret-key`
    - `garage-postgres-backups-access-key`, `garage-postgres-backups-secret-key`
- A smoke-test `ExternalSecret` (`garage-images-creds`) in the `garage` namespace that pulls the `images` keys from GCP SM and materializes them as a K8s Secret with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` keys, ready to consume via `envFrom`

All of this is reconciled by Argo CD via the `garage` Application at `argocd/garage.yaml`. The Application is two-source: source 1 is the upstream Helm chart pulled from the Garage git repo, source 2 is `infra/garage/` (namespace + smoke-test ExternalSecret).

## Why Garage (not MinIO)

Original Phase 0 spec called for MinIO. We swapped during Phase 0 implementation because MinIO removed the admin UI from the OSS/AGPL build in mid-2025 and several senior maintainers left over governance disputes; Garage is actively maintained, S3-compatible, and designed for self-hosted single-node deployments — exactly this cluster's profile. Both speak S3, so consumers (iOS clients, CNPG backups, imgproxy) don't care which backend they're hitting. Full rationale: [danicajiao/cove#213](https://github.com/danicajiao/cove/issues/213).

## Why git+Helm via Argo CD instead of `helm install`

The [upstream Garage Kubernetes cookbook](https://garagehq.deuxfleurs.fr/documentation/cookbook/kubernetes/) walks through `helm install` directly against the chart path. We use the same chart, same values, same pinned version — just rendered by Argo CD instead of by a one-shot `helm install`. The benefit is GitOps: the chart version, the values overrides, and the namespace all live in this repo, change via PR, and reconcile automatically. The downside (vs. a Helm-repo chart like ESO or CNPG) is that we pin a git tag rather than a chart version — Garage doesn't publish to a Helm repo, the chart is versioned alongside the Garage source.

## Prerequisites

- Argo CD already installed and the root app-of-apps reconciling (`docs/argocd-install.md`)
- ESO + the `gcp-cove` ClusterSecretStore operational ([#211](https://github.com/danicajiao/cove/issues/211) / `docs/external-secrets-install.md`) — Step 6 of this runbook depends on it. (Originally introduced as `gcp-secret-manager`; renamed in [#14](https://github.com/danicajiao/homelab/issues/14) once a sibling `gcp-homelab` store landed.)
- `kubectl` pointed at the K3s cluster
- `gcloud` authenticated against the `cove-6a685` GCP project: `gcloud config set project cove-6a685`
- Permission to create secrets in GCP Secret Manager (`roles/secretmanager.admin` or owner) on `cove-6a685`

## Repo layout (relevant pieces)

```
homelab/
├── infra/
│   └── garage/
│       ├── kustomization.yaml          # namespace + smoke-test ExternalSecret
│       ├── namespace.yaml
│       └── external-secret-images.yaml # garage-images-creds (smoke test)
└── argocd/
    └── garage.yaml                     # two-source Application (chart + this dir)
```

The Helm chart itself is **not** vendored; Argo CD pulls it from the Garage source repo at the git tag pinned in `argocd/garage.yaml`. Bumping Garage is a one-line edit in that file (see [Bumping the chart](#bumping-the-chart) below).

> **Note:** Argo CD reaches `git.deuxfleurs.fr` (a self-hosted Gitea, not GitHub) to fetch the chart. If your Argo CD instance has no egress to that host the first sync will fail with a clone error — verify with `kubectl -n argocd logs deploy/argocd-repo-server | tail -50` after the merge.

---

## Step 1 — Merge the chart Application

Merge the PR that adds `infra/garage/` and `argocd/garage.yaml` into `main`. Argo CD's root Application watches `argocd/`, so within ~3 minutes (or immediately if you force a refresh) the `garage` child Application appears and starts reconciling.

Force the refresh:

```bash
kubectl -n argocd annotate application root \
    argocd.argoproj.io/refresh=hard --overwrite
```

Verify the chart Application sync state:

```bash
kubectl -n argocd get application garage
```

`SYNC STATUS` should reach `Synced` and `HEALTH STATUS` should be `Healthy` or `Progressing`. The smoke-test ExternalSecret will report `SecretSyncedError` until Step 6 completes — that's expected (the four GCP secrets don't exist yet).

Confirm the StatefulSet pod is `Running`:

```bash
kubectl -n garage get pods
```

Expected:

```
NAME        READY   STATUS    RESTARTS
garage-0    1/1     Running   0
```

The pod is up, but Garage starts **unconfigured** — no layout, no buckets, no keys. That's what the rest of this runbook fixes.

## Step 2 — Apply the cluster layout

Garage's "layout" is its replication topology: which nodes hold data, how much, in which zones. It's declared at startup and only reapplied when nodes change. For our single-node homelab: one node, zone `dc1`, capacity matching the data PVC.

Find the node ID:

```bash
kubectl -n garage exec garage-0 -- /garage status
```

The output lists each node with its full ID — copy the long hex ID for the local node (the one matching `garage-0`).

Assign the node to a zone with capacity:

```bash
kubectl -n garage exec garage-0 -- /garage layout assign \
    -z dc1 -c 20G <node-id>
```

`-z dc1` is the zone label (just an arbitrary string — pick `dc1` and stick with it). `-c 20G` is the storage capacity advertised to Garage; match it to the data PVC size in `argocd/garage.yaml` (currently 20Gi).

Apply the staged layout:

```bash
kubectl -n garage exec garage-0 -- /garage layout apply --version 1
```

Garage stages layout changes and applies them atomically; `--version 1` is the version number of the new layout (incrementing `layout assign` calls bump the staged version, `layout apply` commits it). Verify:

```bash
kubectl -n garage exec garage-0 -- /garage status
```

The node should now show `HEALTHY` with the capacity and zone you assigned.

## Step 3 — Create buckets

```bash
kubectl -n garage exec garage-0 -- /garage bucket create images
kubectl -n garage exec garage-0 -- /garage bucket create postgres-backups
```

Verify:

```bash
kubectl -n garage exec garage-0 -- /garage bucket list
```

Both buckets should appear with no aliases and zero objects.

## Step 4 — Create access keys

Each bucket gets its own scoped key pair so a credential leak only affects one bucket.

```bash
kubectl -n garage exec garage-0 -- /garage key create cove-images
kubectl -n garage exec garage-0 -- /garage bucket allow images \
    --key cove-images --read --write --owner

kubectl -n garage exec garage-0 -- /garage key create cove-postgres-backups
kubectl -n garage exec garage-0 -- /garage bucket allow postgres-backups \
    --key cove-postgres-backups --read --write --owner
```

> **Important:** each `key create` command prints the key ID **and** the secret access key to stdout exactly once. The secret is **not retrievable later** — Garage stores it hashed. Copy both values immediately to a scratch buffer before moving on. If you lose them, delete the key (`/garage key delete <name>`) and recreate it.

You should now have, captured locally, four values:

- `cove-images` access key ID
- `cove-images` secret access key
- `cove-postgres-backups` access key ID
- `cove-postgres-backups` secret access key

Verify the bucket→key bindings:

```bash
kubectl -n garage exec garage-0 -- /garage bucket info images
kubectl -n garage exec garage-0 -- /garage bucket info postgres-backups
```

Each bucket should list its corresponding key with `RWO` (read, write, owner).

## Step 5 — Store keys in GCP Secret Manager

Push each of the four values into Secret Manager. `echo -n` avoids the trailing newline (matters — S3 SDKs treat the secret literally).

```bash
echo -n "<cove-images-access-key-id>" | gcloud secrets create garage-images-access-key \
    --project cove-6a685 --data-file=- --replication-policy=automatic

echo -n "<cove-images-secret-access-key>" | gcloud secrets create garage-images-secret-key \
    --project cove-6a685 --data-file=- --replication-policy=automatic

echo -n "<cove-postgres-backups-access-key-id>" | gcloud secrets create garage-postgres-backups-access-key \
    --project cove-6a685 --data-file=- --replication-policy=automatic

echo -n "<cove-postgres-backups-secret-access-key>" | gcloud secrets create garage-postgres-backups-secret-key \
    --project cove-6a685 --data-file=- --replication-policy=automatic
```

Confirm all four exist:

```bash
gcloud secrets list --project cove-6a685 --filter="name:garage-"
```

Once verified, scrub the keys from your scratch buffer / shell history. The cluster + GCP SM are now the only copies.

## Step 6 — Force-sync the smoke-test ExternalSecret

The `garage-images-creds` ExternalSecret has been failing with `SecretSyncedError` since the chart Application reconciled (the GCP secrets didn't exist yet). Now that they do, force a sync:

```bash
kubectl -n garage annotate externalsecret garage-images-creds \
    force-sync=$(date +%s) --overwrite
```

Verify the K8s Secret materializes:

```bash
kubectl -n garage get externalsecret garage-images-creds
kubectl -n garage get secret garage-images-creds -o yaml
```

Status should be `SecretSynced` / `Ready`. The Secret should have `data.AWS_ACCESS_KEY_ID` and `data.AWS_SECRET_ACCESS_KEY` populated. Spot-check a value:

```bash
kubectl -n garage get secret garage-images-creds \
    -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d
# → should match the cove-images access key ID from Step 4
```

## Step 7 — Smoke test the S3 round-trip

End-to-end check: a temporary pod uses the synced credentials to PUT, GET, and DELETE an object in the `images` bucket via the in-cluster S3 endpoint.

```bash
kubectl -n garage run s3-smoke --rm -i --tty --restart=Never \
    --image=amazon/aws-cli:latest \
    --env="AWS_ACCESS_KEY_ID=$(kubectl -n garage get secret garage-images-creds -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)" \
    --env="AWS_SECRET_ACCESS_KEY=$(kubectl -n garage get secret garage-images-creds -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)" \
    --env="AWS_DEFAULT_REGION=garage" \
    --command -- sh -c '
        set -e
        ENDPOINT=http://garage.garage.svc.cluster.local:3900
        echo "hello-from-garage" > /tmp/probe.txt
        aws --endpoint-url $ENDPOINT s3 cp /tmp/probe.txt s3://images/probe.txt
        aws --endpoint-url $ENDPOINT s3 cp s3://images/probe.txt /tmp/probe-readback.txt
        diff /tmp/probe.txt /tmp/probe-readback.txt && echo "ROUND-TRIP OK"
        aws --endpoint-url $ENDPOINT s3 rm s3://images/probe.txt
        echo "DELETE OK"
    '
```

Expected tail of the output:

```
ROUND-TRIP OK
DELETE OK
```

If the PUT errors with `403`/`AccessDenied`, recheck Step 4 (`bucket allow`). If it errors with a connection refused / DNS failure, the Service name is wrong — confirm with `kubectl -n garage get svc` (the chart's release name is `garage`, so the Service is `garage` in the `garage` namespace, hence the `garage.garage.svc.cluster.local` FQDN). The S3 API listens on port 3900 (chart default).

That's it — Garage is up, both buckets exist, both key pairs work, ESO is wired through to the bucket creds, and a real S3 client can read/write.

---

## How to add a new bucket consumer

When a Phase 1+ service needs access to `images` or `postgres-backups`, create an `ExternalSecret` in **its** namespace pointing at the same GCP secrets:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
    name: <service>-s3-creds
    namespace: <service-namespace>
spec:
    refreshInterval: 1h
    secretStoreRef:
        kind: ClusterSecretStore
        name: gcp-cove
    target:
        name: <service>-s3-creds
        creationPolicy: Owner
    data:
        - secretKey: AWS_ACCESS_KEY_ID
          remoteRef:
              key: garage-images-access-key
        - secretKey: AWS_SECRET_ACCESS_KEY
          remoteRef:
              key: garage-images-secret-key
```

Mount it on the consumer Deployment via `envFrom: [{secretRef: {name: <service>-s3-creds}}]`. Same `gcp-cove` ClusterSecretStore, no per-namespace bootstrap needed.

## Adding more buckets later

```bash
# Inside the running pod:
kubectl -n garage exec garage-0 -- /garage bucket create <new-bucket>
kubectl -n garage exec garage-0 -- /garage key create cove-<new-bucket>
kubectl -n garage exec garage-0 -- /garage bucket allow <new-bucket> \
    --key cove-<new-bucket> --read --write --owner

# Then mirror in GCP SM (Step 5 pattern):
echo -n "<access-key-id>" | gcloud secrets create garage-<new-bucket>-access-key \
    --project cove-6a685 --data-file=- --replication-policy=automatic
echo -n "<secret-access-key>" | gcloud secrets create garage-<new-bucket>-secret-key \
    --project cove-6a685 --data-file=- --replication-policy=automatic
```

If you want a smoke-test ExternalSecret in this repo for the new bucket, mirror `infra/garage/external-secret-images.yaml` and add it to `infra/garage/kustomization.yaml`.

---

## Bumping the chart

The Garage chart is versioned alongside the Garage source — bumping the chart means bumping the Garage release tag, which in turn rolls the StatefulSet to a new Garage version.

1. Pick a new tag from <https://git.deuxfleurs.fr/Deuxfleurs/garage/tags> (or `git ls-remote --tags https://git.deuxfleurs.fr/Deuxfleurs/garage.git`).
2. Edit `targetRevision` in `argocd/garage.yaml`.
3. Verify locally that the repo-managed pieces still parse: `kubectl kustomize infra/garage/`. (The chart itself is rendered by Argo CD, not by kustomize — this only confirms the namespace + ExternalSecret are valid.)
4. Open a PR. Once merged, Argo CD reconciles the new chart version. Watch `kubectl -n garage get pods -w` during the rollout; the StatefulSet should roll cleanly without restart loops, and `garage status` should still show the node as `HEALTHY` afterward.
5. If something goes wrong, revert the PR. The PVC + layout + buckets + keys all survive a chart rollback (they live on disk and in the metadata DB, not in chart-managed resources).

Read the Garage release notes before bumping across a major version (e.g. v2.x → v3.x) — major versions sometimes require an offline metadata migration.
