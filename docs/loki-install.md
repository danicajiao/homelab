# Loki + Alloy Install Runbook

> One-time install of [Grafana Loki](https://grafana.com/oss/loki/) (log aggregation) and [Grafana Alloy](https://grafana.com/oss/alloy/) (log collection DaemonSet) on the homelab K3s cluster. After this runbook, every pod's stdout/stderr is queryable from the same Grafana instance that already shows Prometheus metrics — pivot from a CPU spike chart to the underlying log lines without leaving the page.

## What this sets up

| Component | Purpose |
|---|---|
| **Loki** | Log aggregation backend. SingleBinary deployment (one StatefulSet pod), all log chunks + indexes stored in Garage S3, 10Gi local PVC for WAL + working state, 14-day retention enforced by the compactor |
| **Alloy** | Log collector DaemonSet. One pod per node tailing `/var/log/pods/*/*.log`, forwarding to the in-cluster Loki Service |
| **Loki Grafana datasource** | Auto-provisioned via `grafana.additionalDataSources` in the existing kube-prometheus-stack Application — Grafana picks it up on the next reconcile |

All of this is reconciled by Argo CD via two new Applications: `loki` at `argocd/loki.yaml` and `alloy` at `argocd/alloy.yaml`. Each is a two-source manifest (chart + this repo's matching `infra/` dir).

## Why Alloy (not Promtail)

Promtail was deprecated in 2024 in favor of [Grafana Alloy](https://grafana.com/blog/2025/01/13/grafana-alloy-is-the-stable-replacement-for-grafana-agent/), the unified telemetry collector that replaces Promtail, Grafana Agent, and (eventually) the OTel Collector across the Grafana stack. Same job (tail files, forward to Loki), one config language (River) for logs / metrics / traces, and active upstream development.

If a future workload needs traces or wants to push metrics from a non-Prometheus-native source, the same Alloy DaemonSet handles it — no second agent.

## Why Garage S3 (not filesystem PVC)

Loki supports either a filesystem PVC or an S3-compatible object store. We use Garage S3 because:

- **Multi-node future.** The plan to add a second K3s node (GPU box) requires a storage backend that's reachable from any node. A `local-path` PVC binds Loki to one node forever. Migrating to S3 later means re-indexing every chunk.
- **We already have Garage.** Same cluster-internal S3 endpoint used by the `images` and `postgres-backups` buckets — adding `loki` is one bucket-create command.
- **Object storage is Loki's recommended backend.** Filesystem mode is for local dev and small homelabs that don't plan to grow; everything else uses S3.

The trade-off: log queries now traverse a network hop to Garage. At single-node scale the latency is negligible (same node, Service DNS), but if log volume grows past ~1 TB/day, SimpleScalable mode + memcached front-cache become attractive.

## Prerequisites

- Argo CD already installed and the root app-of-apps reconciling. See [docs/argocd-install.md](argocd-install.md).
- ESO installed and both ClusterSecretStores `Valid`. See [docs/external-secrets-install.md](external-secrets-install.md). In particular, `gcp-homelab` must be working — the smoke test for that is the Grafana `grafana-admin-creds` ExternalSecret from kube-prometheus-stack.
- Garage installed and running. See [docs/garage-install.md](garage-install.md).
- kube-prometheus-stack installed (provides the Grafana instance Loki gets wired into as a datasource). See [docs/kube-prometheus-stack-install.md](kube-prometheus-stack-install.md).
- `kubectl` pointed at the K3s cluster.
- `gcloud` authenticated and able to write to project `homelab-495921`.

## Repo layout (relevant pieces)

```
homelab/
├── infra/
│   ├── loki/
│   │   ├── kustomization.yaml          # ExternalSecret only
│   │   └── external-secret.yaml        # loki-creds via gcp-homelab
│   └── alloy/
│       └── kustomization.yaml          # placeholder (no resources yet)
└── argocd/
    ├── loki.yaml                       # two-source Application (chart + infra/loki/)
    └── alloy.yaml                      # two-source Application (chart + infra/alloy/)
```

Neither Helm chart is vendored; Argo CD pulls them from `https://grafana.github.io/helm-charts` at the versions pinned in `argocd/loki.yaml` (chart `loki` v7.0.0) and `argocd/alloy.yaml` (chart `alloy` v1.8.1). Bumping either chart is a one-line edit in the corresponding file.

The Grafana datasource is wired via a `grafana.additionalDataSources` block in `argocd/kube-prometheus-stack.yaml` — no separate ConfigMap.

---

## Step 1 — Create the Garage `loki` bucket and access key

These are one-time Garage CLI operations, run inside the Garage pod. Same flow as the original `images` bucket bootstrap in [docs/garage-install.md](garage-install.md).

```bash
kubectl -n garage exec garage-0 -- /garage bucket create loki
kubectl -n garage exec garage-0 -- /garage key create homelab-loki
kubectl -n garage exec garage-0 -- /garage bucket allow loki \
    --key homelab-loki --read --write --owner
```

The `key create` command prints the access key ID and secret key — capture both before moving on. There is no way to retrieve the secret key from Garage after this point; if you lose it, delete the key and create a new one.

## Step 2 — Upload credentials to GCP Secret Manager

The credentials live in the `homelab-495921` project, same as the Grafana admin password — Loki is cluster-wide observability infra (per the consumer-owns rule in [external-secrets-install.md](external-secrets-install.md)).

```bash
echo -n "<paste-access-key-id>" | gcloud secrets create loki-access-key \
    --project homelab-495921 --data-file=- --replication-policy=automatic

echo -n "<paste-secret-key>" | gcloud secrets create loki-secret-key \
    --project homelab-495921 --data-file=- --replication-policy=automatic
```

Verify:

```bash
gcloud secrets versions access latest --secret=loki-access-key --project=homelab-495921
gcloud secrets versions access latest --secret=loki-secret-key --project=homelab-495921
```

Both should echo back the values you uploaded.

> **Use single quotes if your secret key contains shell metacharacters** (`$`, `` ` ``, `!`). Garage-generated keys are URL-safe base64 so this is unlikely, but harmless to wrap.

## Step 3 — Merge the PR

Merge the PR that adds `argocd/loki.yaml`, `argocd/alloy.yaml`, `infra/loki/`, and `infra/alloy/` to `main`, plus the small addition to `argocd/kube-prometheus-stack.yaml` (the Loki datasource block). Argo CD's root Application watches `argocd/`, so within ~3 minutes (or immediately if you `argocd app sync root` or hard-refresh in the UI) the two new child Applications appear and start reconciling.

The first reconcile does:

1. Loki chart renders → `monitoring/loki` StatefulSet + Service + ConfigMap + ServiceAccount + PVC (10Gi `local-path` for WAL + indexes)
2. `loki-creds` ExternalSecret materializes the Garage credentials as a K8s Secret in `monitoring`
3. Loki pod starts, reads `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from the secret via `envFrom`, connects to Garage on `http://garage.garage.svc.cluster.local:3900`, initializes the `loki` bucket layout
4. Alloy chart renders → `monitoring/alloy` DaemonSet + ConfigMap (River config) + ClusterRole + ClusterRoleBinding
5. Alloy pod starts on each node, lists pods via the K8s API, opens file handles on `/var/log/pods/*/*.log` for pods on its own node, begins forwarding
6. kube-prometheus-stack re-reconciles with the new datasource block, the Grafana pod rolls, and `Loki` shows up under Connections → Data sources

## Step 4 — Verify

### Applications are Synced + Healthy

```bash
kubectl -n argocd get application loki alloy
```

Both expected `Synced` / `Healthy`. If you see `OutOfSync`, see [Drift on first reconcile](#drift-on-first-reconcile) below.

### Pods are Running

```bash
kubectl -n monitoring get pods -l 'app.kubernetes.io/name in (loki,alloy)'
```

Expected (names will have hash suffixes):

```
NAME       READY   STATUS    RESTARTS
alloy-xxxxx           2/2     Running   0
loki-0                1/1     Running   0
```

One `alloy` pod per node — at this stage the cluster is single-node, so one. `loki-0` is the SingleBinary StatefulSet pod.

### ExternalSecret materialized

```bash
kubectl -n monitoring get externalsecret loki-creds
kubectl -n monitoring get secret loki-creds
```

`STATUS` should be `SecretSynced`. Both keys should exist:

```bash
kubectl -n monitoring get secret loki-creds \
    -o jsonpath='{.data}' | jq 'keys'
# → ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
```

### Loki is reachable inside the cluster

```bash
kubectl -n monitoring port-forward svc/loki 3100:3100
```

Then in another shell:

```bash
curl -s http://localhost:3100/ready
# → ready

curl -s http://localhost:3100/metrics | head -20
# → loki_* prometheus metrics
```

### Logs are being ingested

Port-forward Grafana:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Log in with the admin credentials from [kube-prometheus-stack-install.md](kube-prometheus-stack-install.md). Open Explore → switch the datasource picker (top-left) to `Loki` → run:

```logql
{namespace="argocd"}
```

You should see recent log lines from the Argo CD pods. Repeat for the other Phase 0 namespaces:

```logql
{namespace="cnpg-system"}
{namespace="garage"}
{namespace="gaming"}
{namespace="external-secrets"}
{namespace="monitoring"}
```

All five should return log lines from the last few minutes.

### Loki self-metrics are being scraped

`http://localhost:9090/targets` (after `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090`) should show `serviceMonitor/monitoring/loki/0` and `serviceMonitor/monitoring/alloy/0` both `UP`.

---

## How to query logs in Grafana

Grafana → Explore → datasource `Loki`. LogQL examples:

```logql
# All logs from a namespace
{namespace="argocd"}

# All logs from a specific pod (exact name)
{namespace="argocd", pod="argocd-server-7c9f8c8c8c-abcde"}

# All logs from any pod matching an app label
{namespace="gaming", app="minecraft"}

# All logs from a node (handy when a node is misbehaving)
{node="homelab"}

# Combine label match with text search (case-insensitive substring)
{namespace="garage"} |~ "(?i)error"

# Same, but for the last hour, formatted as JSON
{namespace="cnpg-system"} | json

# Count log lines per pod over the last 5 minutes (top talkers)
sum by (pod) (count_over_time({namespace="monitoring"}[5m]))

# Rate of error-level lines per namespace, last 1 minute
sum by (namespace) (rate({namespace=~".+"} |~ "(?i)error|fail|panic"[1m]))
```

The available labels on every stream are: `namespace`, `pod`, `container`, `app`, `node`. They come from the relabel pipeline in `argocd/alloy.yaml` — see the River config there if you want to add another label (carefully — every unique combination is a separate stream, and high cardinality tanks query performance).

---

## How to add a new log source

Out of the box, Alloy tails **every** pod's stdout/stderr via `/var/log/pods` — no per-workload config needed. The vast majority of new services are picked up automatically the moment a pod starts.

For workloads that write logs to a file *inside the container* (rather than stdout), the cleanest path is to either:

1. **Pipe the file to stdout** in the container command — `tail -F /path/to/log` as a sidecar or as the main process. Logs flow through the runtime to `/var/log/pods` and are picked up by the existing pipeline. Zero Alloy config.
2. **Mount a hostPath volume** that Alloy can also see, then add a second `local.file_match` / `loki.source.file` pair to the River config in `argocd/alloy.yaml`. Avoid this unless option 1 is impossible — hostPath couples the workload to the node.

If you do edit the River config, the chart's config-reloader sidecar picks up the ConfigMap change automatically; no DaemonSet restart needed.

---

## Drift on first reconcile

Loki and Alloy are the fifth and sixth Helm-chart Applications we've installed. Each of the prior four (ESO, CNPG, Garage, kube-prometheus-stack) surfaced drift on first reconcile — typical patterns:

1. **Chart-generated random Secrets** — chart re-rolls a value on every render (Loki's `kube_root_ca.crt` token isn't an example of this, but the per-StatefulSet bootstrap token can be).
2. **Admission-controller mutations** — ESO's webhook auto-fills `conversionStrategy / decodingStrategy / metadataPolicy / nullBytePolicy` and `target.deletionPolicy` on every `ExternalSecret`. Same applies to the new `loki-creds` ExternalSecret here.
3. **Server-side defaults** — `volumeClaimTemplates[].apiVersion` / `kind` stripped by K8s admission, same drift Garage's StatefulSet shows.

We deliberately did **not** preemptively add an `ignoreDifferences` block to either new Application (same pattern as ESO [#5](https://github.com/danicajiao/homelab/pull/5), Garage [#9](https://github.com/danicajiao/homelab/pull/9), kube-prometheus-stack [#18](https://github.com/danicajiao/homelab/pull/18)). The plan is to observe what actually surfaces in this cluster on first reconcile and add targeted rules in a follow-up PR.

If `loki` or `alloy` shows `OutOfSync` post-install:

1. Open the Argo CD UI → the Application → Diff. Screenshot the diff.
2. Identify which fields are drifting.
3. Open a follow-up PR adding an `ignoreDifferences` block mirroring the structure in `argocd/garage.yaml` (`jqPathExpressions` for `[]` traversal, `jsonPointers` for fixed paths). Add `RespectIgnoreDifferences=true` to `syncOptions` so selfHeal stops fighting the webhook.

> The `loki-creds` ExternalSecret almost certainly needs the same ESO-webhook-defaulted-fields rule as the other four ExternalSecrets in the repo. This is now the fifth Application with the same rule pending — strong case for lifting it to the AppProject level via cluster-wide `resource.customizations.ignoreDifferences` config in `argocd-cm`. Tracked as a follow-up (homelab #19).

---

## Day-2 — Bumping the charts

### Loki

1. Edit `targetRevision` in `argocd/loki.yaml`.
2. Verify locally: `kubectl kustomize infra/loki/` (just to confirm the ExternalSecret still parses — the chart itself is rendered by Argo CD, not by kustomize).
3. Open a PR. Once merged, Argo CD reconciles the new chart version. Watch `kubectl -n monitoring get pods -l app.kubernetes.io/name=loki -w` during the rollout.
4. Read the chart's [release notes](https://github.com/grafana/helm-charts/releases?q=loki&expanded=true) for breaking changes — Loki has gone through multiple storage / schema config refactors. Major bumps (e.g. 6.x → 7.x) sometimes rename values keys.
5. **Schema changes** require a new entry in `loki.schemaConfig.configs` with a future `from:` date, not editing the existing entry in place. The on-disk indexes are stamped with the schema version that wrote them; old data stays readable on the old schema, new writes use the new schema after the cutover date.
6. If something goes wrong, revert the PR. Argo CD will roll back on next reconcile. Data in Garage is untouched — Loki indexes survive a downgrade as long as schemaConfig is consistent.

### Alloy

1. Edit `targetRevision` in `argocd/alloy.yaml`.
2. Open a PR. Once merged, Argo CD reconciles the new chart version.
3. Read the chart's [release notes](https://github.com/grafana/helm-charts/releases?q=alloy&expanded=true). Alloy's River component reference is versioned alongside the appVersion; component names and arguments are stable across patches but occasionally renamed on majors.

Latest releases: <https://github.com/grafana/helm-charts/releases>

---

## Troubleshooting

### `loki` Application is `OutOfSync`

See [Drift on first reconcile](#drift-on-first-reconcile) above.

### Loki pod stuck `CrashLoopBackOff` with "AccessDenied" / "InvalidAccessKeyId" / "NoSuchBucket"

The `loki-creds` Secret hasn't materialized, or the values are wrong, or the bucket doesn't exist.

```bash
kubectl -n monitoring describe externalsecret loki-creds
kubectl -n monitoring get secret loki-creds -o yaml
kubectl -n monitoring logs loki-0
```

If `STATUS: SecretSyncedError`, the most common cause is that the GCP secrets `loki-access-key` / `loki-secret-key` don't exist in `homelab-495921`. Re-run Step 2.

If the keys exist but Loki still rejects them, double-check the Garage CLI output from Step 1 against what you uploaded — paste errors are easy.

If `NoSuchBucket`, the bucket-create from Step 1 didn't run or ran against a different Garage instance. Re-run Step 1.

### Alloy pods Running but no logs in Grafana

```bash
# Check Alloy is actually scraping
kubectl -n monitoring logs -l app.kubernetes.io/name=alloy --tail=100

# Hit Alloy's UI (port 12345 on each pod) and look at the Components view
# — every loki.source.file component should show non-zero targets and
# non-zero "lines forwarded".
kubectl -n monitoring port-forward ds/alloy 12345:12345
# Open http://localhost:12345
```

Most common causes:

- The `/var/log/pods` mount isn't there. Check `alloy.mounts.varlog: true` is still set in `argocd/alloy.yaml` and that the rendered pod spec has the corresponding `volumeMount`.
- The Loki Service is unreachable. From an Alloy pod: `wget -qO- http://loki.monitoring.svc.cluster.local:3100/ready`. Should print `ready`.
- The relabel pipeline is dropping every target. Check the Components view — `discovery.relabel.pod_logs` should show non-zero output targets.

### A Loki query returns "too many outstanding requests"

The single-binary querier is saturated. Either bump `loki.querier.max_concurrent` in `argocd/loki.yaml`, or scale up by switching `deploymentMode: SimpleScalable` (read/write split). At homelab scale this is rare.

### Want to wipe Loki and start over

```bash
# Tear down the StatefulSet and its PVC (in-flight WAL data is lost; chunks
# in Garage survive)
kubectl -n monitoring delete statefulset loki
kubectl -n monitoring delete pvc storage-loki-0

# Wipe the Garage bucket contents (does NOT delete the bucket itself)
kubectl -n garage exec garage-0 -- /garage bucket info loki   # to confirm
# (deletion via Garage CLI is bucket-scoped; use the AWS CLI through the
# `homelab-loki` key for object-level deletes, or recreate the bucket
# entirely if you don't mind the key churn)
```

Argo CD's selfHeal will recreate the StatefulSet and PVC on the next reconcile.
