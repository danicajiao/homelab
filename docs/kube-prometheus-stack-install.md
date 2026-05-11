# kube-prometheus-stack Install Runbook

> One-time install of [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) on the homelab K3s cluster. After this runbook, every operator (Argo CD, External Secrets, CloudNativePG, Garage) and every future cove service is observable from a single Grafana, with Prometheus storing metrics and Alertmanager routing alerts.

## What this sets up

| Component | Purpose |
|---|---|
| **Prometheus** | Time-series metrics database, 10d retention, 20Gi PVC on `local-path` |
| **Grafana** | Dashboards. Admin password sourced from GCP SM (`homelab-495921` → `grafana-admin-password`) via ESO. Dashboard state persisted on a 5Gi PVC |
| **Alertmanager** | Alert routing + deduplication, 2Gi PVC on `local-path` |
| **node-exporter** | Host-level metrics (CPU, memory, disk, network) as a DaemonSet |
| **kube-state-metrics** | Kubernetes object-level metrics (Deployments, Pods, PVCs, etc.) |
| **Prometheus Operator** | Manages the Prometheus / Alertmanager / ServiceMonitor / PodMonitor / PrometheusRule CRDs |
| Default dashboards | The upstream [kubernetes-mixin](https://github.com/kubernetes-monitoring/kubernetes-mixin) (cluster, node, pod, namespace overviews) pre-baked into the chart |

All of this is reconciled by Argo CD via the `kube-prometheus-stack` Application at `argocd/kube-prometheus-stack.yaml`. The Application is a two-source manifest: source 1 is the upstream Helm chart, source 2 is `infra/kube-prometheus-stack/` (namespace + ExternalSecret + four Argo CD ServiceMonitors + Garage PodMonitor).

ServiceMonitor coverage for the other Phase 0 operators is wired in two ways:

| Operator | How metrics are discovered |
|---|---|
| **Argo CD** | Four ServiceMonitors in `infra/kube-prometheus-stack/servicemonitor-argocd.yaml` (argocd-metrics, argocd-server-metrics, argocd-repo-server, argocd-applicationset-controller). Argo CD's raw `install.yaml` doesn't ship ServiceMonitors of its own |
| **CloudNativePG** | Chart auto-creates a PodMonitor — enabled via `monitoring.podMonitorEnabled: true` in `argocd/cnpg.yaml` |
| **External Secrets** | Chart auto-creates a ServiceMonitor — enabled via `serviceMonitor.enabled: true` in `argocd/external-secrets.yaml` |
| **Garage** | PodMonitor in `infra/kube-prometheus-stack/podmonitor-garage.yaml`. Garage's chart deliberately does NOT expose port 3903 on its Service, so a ServiceMonitor won't work — PodMonitor scrapes the pod IP directly |
| **kube-prometheus-stack itself** | Auto-included by the chart |

## Why externalize the Grafana admin password?

By default the kube-prometheus-stack chart generates a random Grafana admin password on first install and stores it in a chart-owned K8s Secret. That works but the value is bound to a single install — re-installing the chart on a fresh cluster (or moving to a different cluster) gives a different password every time, with no record outside the cluster.

Putting the password in GCP Secret Manager makes it stable across reinstalls and visible in our normal secret pipeline (alongside the Garage S3 keys, CurseForge API key, etc.). ESO syncs it into `monitoring/grafana-admin-creds` and we point `grafana.admin.existingSecret` at that K8s Secret.

This matches the **consumer-owns** rule in [docs/external-secrets-install.md](external-secrets-install.md): Grafana is cluster-wide homelab infra, not a cove product surface, so the GCP secret lives in `homelab-495921` and is accessed via the `gcp-homelab` ClusterSecretStore.

## Prerequisites

- Argo CD already installed and the root app-of-apps reconciling. See [docs/argocd-install.md](argocd-install.md).
- ESO installed and both ClusterSecretStores `Valid`. See [docs/external-secrets-install.md](external-secrets-install.md). In particular, `gcp-homelab` must be working — the smoke test for that is the Minecraft `minecraft-curseforge-key` ExternalSecret.
- `kubectl` pointed at the K3s cluster.
- `gcloud` authenticated and able to write to project `homelab-495921`.

## Repo layout (relevant pieces)

```
homelab/
├── infra/
│   └── kube-prometheus-stack/
│       ├── kustomization.yaml              # namespace + ExternalSecret + Argo CD/Garage monitors
│       ├── namespace.yaml
│       ├── external-secret.yaml            # grafana-admin-creds via gcp-homelab
│       ├── servicemonitor-argocd.yaml      # 4 ServiceMonitors for Argo CD's metrics services
│       └── podmonitor-garage.yaml          # PodMonitor for Garage admin port 3903
└── argocd/
    └── kube-prometheus-stack.yaml          # two-source Application (chart + this dir)
```

The Helm chart itself is **not** vendored; Argo CD pulls it from `https://prometheus-community.github.io/helm-charts` at the version pinned in `argocd/kube-prometheus-stack.yaml`. Bumping the chart is a one-line edit in that file.

---

## Step 1 — Generate the admin password and upload to GCP SM

Generate a strong password locally:

```bash
openssl rand -base64 32 | tr -d '/+=' | head -c 32
```

Copy the output. **Don't lose it before Step 4** — once it's in GCP SM you can also retrieve it from there, but having a local copy is convenient for the first login.

Upload to the `homelab-495921` project:

```bash
echo -n "<paste-password>" | gcloud secrets create grafana-admin-password \
    --project homelab-495921 \
    --data-file=- \
    --replication-policy=automatic
```

Verify:

```bash
gcloud secrets versions access latest \
    --secret=grafana-admin-password \
    --project=homelab-495921
```

You should see the password echoed back.

> **Use single quotes if your password contains shell metacharacters** (`$`, `` ` ``, etc.). The `openssl ... | tr -d '/+='` recipe above strips the worst offenders, but it's still safer to wrap the value.

## Step 2 — Merge the PR

Merge the PR that adds `argocd/kube-prometheus-stack.yaml` and `infra/kube-prometheus-stack/` to `main`. Argo CD's root Application watches `argocd/`, so within ~3 minutes (or immediately if you `argocd app sync root` or hard-refresh in the UI) the `kube-prometheus-stack` child Application appears and starts reconciling.

The first reconcile installs:

1. The chart's CRDs (`prometheuses`, `alertmanagers`, `servicemonitors`, `podmonitors`, `prometheusrules`, `thanosrulers`, `probes`, `alertmanagerconfigs`, `scrapeconfigs`)
2. The `monitoring` namespace
3. The Prometheus Operator Deployment
4. The Prometheus `Prometheus` CR + StatefulSet
5. The Alertmanager `Alertmanager` CR + StatefulSet
6. The Grafana Deployment (or StatefulSet with `persistence.type: sts`)
7. kube-state-metrics Deployment + node-exporter DaemonSet
8. The `grafana-admin-creds` ExternalSecret (Owner over the K8s Secret of the same name)
9. The four Argo CD ServiceMonitors + the Garage PodMonitor
10. The chart-auto-created ESO ServiceMonitor + CNPG PodMonitor (as a side effect of the chart-values changes to `argocd/external-secrets.yaml` and `argocd/cnpg.yaml`)

## Step 3 — Verify

### Application is Synced + Healthy

```bash
kubectl -n argocd get application kube-prometheus-stack
```

Expect `Synced` / `Healthy`. If you see `OutOfSync`, see [Drift on first reconcile](#drift-on-first-reconcile) below.

### Pods are Running

```bash
kubectl -n monitoring get pods
```

Expected (names will have hash suffixes):

```
NAME                                                          READY   STATUS    RESTARTS
alertmanager-kube-prometheus-stack-alertmanager-0             2/2     Running   0
kube-prometheus-stack-grafana-0                               3/3     Running   0
kube-prometheus-stack-kube-state-metrics-xxxxxxxxxx-xxxxx     1/1     Running   0
kube-prometheus-stack-operator-xxxxxxxxxx-xxxxx               1/1     Running   0
kube-prometheus-stack-prometheus-node-exporter-xxxxx          1/1     Running   0
prometheus-kube-prometheus-stack-prometheus-0                 2/2     Running   0
```

(One `node-exporter` pod per node — at this stage the cluster is single-node, so one.)

### CRDs are registered

```bash
kubectl get crd | grep monitoring.coreos.com
```

Expect at least: `prometheuses`, `alertmanagers`, `servicemonitors`, `podmonitors`, `prometheusrules`, `thanosrulers`, `probes`, `alertmanagerconfigs`, `scrapeconfigs`.

### ExternalSecret materialized

```bash
kubectl -n monitoring get externalsecret grafana-admin-creds
kubectl -n monitoring get secret grafana-admin-creds
```

`STATUS` should be `SecretSynced`. Confirm both keys exist:

```bash
kubectl -n monitoring get secret grafana-admin-creds \
    -o jsonpath='{.data}' | jq 'keys'
# → ["admin-password", "admin-user"]
```

### Targets are UP in Prometheus

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Then in a browser, hit <http://localhost:9090/targets>. You should see all of these with state `UP`:

- `serviceMonitor/monitoring/argocd-metrics/0`
- `serviceMonitor/monitoring/argocd-server-metrics/0`
- `serviceMonitor/monitoring/argocd-repo-server-metrics/0`
- `serviceMonitor/monitoring/argocd-applicationset-controller-metrics/0`
- `podMonitor/monitoring/garage/0`
- `serviceMonitor/external-secrets/external-secrets/0` (chart-auto-created)
- `podMonitor/cnpg-system/cnpg-cloudnative-pg/0` (chart-auto-created)
- All the chart's built-in targets (`prometheus`, `alertmanager`, `grafana`, `kube-state-metrics`, `node-exporter`, `kubelet`, `apiserver`, `coredns`)

> The chart's `kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, and `kubeProxy` ServiceMonitors are intentionally disabled — K3s runs these as embedded processes inside the `k3s-server` binary, not as separate pods, so the default targets would be permanently `DOWN`. See the comment in `argocd/kube-prometheus-stack.yaml`.

### Alerts are loaded

<http://localhost:9090/alerts> should show ~80 default alert rules from the chart, all in state `inactive` (firing rules indicate a real issue).

## Step 4 — Accessing Grafana

Port-forward the Service:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Open <http://localhost:3000>. Log in with:

- **Username:** `admin`
- **Password:** the value you stored in GCP SM in Step 1. Retrieve it via:
    ```bash
    kubectl -n monitoring get secret grafana-admin-creds \
        -o jsonpath='{.data.admin-password}' | base64 -d
    ```
    (or `gcloud secrets versions access latest --secret=grafana-admin-password --project=homelab-495921`)

Expected dashboards on first login (left sidebar → Dashboards → Browse):

- **Kubernetes / Compute Resources / Cluster** — cluster-wide CPU/memory usage
- **Kubernetes / Compute Resources / Namespace (Pods)** — per-namespace pod resource usage
- **Kubernetes / Compute Resources / Pod** — drill-in to a single pod
- **Kubernetes / Compute Resources / Node (Pods)** — per-node pod density
- **Kubernetes / Networking / Cluster**
- **Node Exporter / Nodes** — host-level CPU/memory/disk/network from node-exporter
- **Prometheus / Overview** — Prometheus self-health
- **Alertmanager / Overview**

The full set comes from the [kubernetes-mixin](https://github.com/kubernetes-monitoring/kubernetes-mixin) baked into the chart.

> **The 5Gi Grafana PVC persists** dashboards saved through the UI, data source tweaks, and plugin installs across pod restarts. Chart-provisioned dashboards live in ConfigMaps (not the PVC) and don't count against this budget.

---

## How to add a new ServiceMonitor

When a future service (cove or otherwise) needs to be scraped, drop a `ServiceMonitor` next to its Deployment:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
    name: <service>-metrics
    namespace: <consumer-namespace>
    labels:
        # Required — chart's default serviceMonitorSelector matches on this
        # (chart default `serviceMonitorSelectorNilUsesHelmValues: true`
        # resolves to a selector of `release=kube-prometheus-stack`).
        release: kube-prometheus-stack
spec:
    selector:
        matchLabels:
            app.kubernetes.io/name: <service>
    endpoints:
        - port: metrics    # the Service port name that exposes /metrics
```

For pod-direct scrapes (Service doesn't expose the metrics port, or you want per-pod entries), use a `PodMonitor` instead — see `infra/kube-prometheus-stack/podmonitor-garage.yaml` as a worked example.

Drop the `release: kube-prometheus-stack` label and Prometheus silently ignores the manifest. Double-check via `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` → Status → Service Discovery → look for the new target.

---

## Drift on first reconcile

kube-prometheus-stack has three known drift sources we've seen at install time on similar operators:

1. **Prometheus Operator webhook mutates `ServiceMonitor` / `PodMonitor` labels** at admission time (canonicalizes `app.kubernetes.io/managed-by`, etc.). Argo CD reports OutOfSync forever and selfHeal fights the webhook on every reconcile.
2. **Chart-generated random Secrets** (Grafana session keys, OAuth state) — chart re-rolls the value on every render.
3. **Alertmanager config Secret content** — operator-controlled.

We deliberately did **not** preemptively add an `ignoreDifferences` block (see comment on `argocd/kube-prometheus-stack.yaml`). The plan is to observe what actually surfaces in this cluster on first reconcile and add targeted rules in a follow-up PR — same pattern as ESO ([#5](https://github.com/danicajiao/homelab/pull/5)) and Garage ([#9](https://github.com/danicajiao/homelab/pull/9)).

If `kube-prometheus-stack` shows `OutOfSync` post-install:

1. Open the Argo CD UI → the Application → Diff. Screenshot the diff.
2. Identify which fields are drifting (typical: `metadata.labels`, `data.*` in Secrets, `.spec.endpoints[].metricRelabelings`).
3. Open a follow-up PR adding an `ignoreDifferences` block to `argocd/kube-prometheus-stack.yaml` mirroring the structure in `argocd/garage.yaml` (`jqPathExpressions` for `[]` traversal, `jsonPointers` for fixed paths). Add `RespectIgnoreDifferences=true` to `syncOptions` so selfHeal stops fighting the webhook.

> The matching `ignoreDifferences` rule for ESO's webhook-defaulted fields already exists on `argocd/external-secrets.yaml`. **Per-Application rules don't compose** — if the chart-auto-created CNPG/ESO ServiceMonitors surface their own drift, the rule needs to live on `argocd/kube-prometheus-stack.yaml` (which owns those resources via the chart). The longer-term cleanup is lifting these rules to the AppProject level; tracked as a follow-up.

---

## Day-2 — Bumping the chart

1. Edit `targetRevision` in `argocd/kube-prometheus-stack.yaml`.
2. Verify locally: `kubectl kustomize infra/kube-prometheus-stack/` (just to confirm the CRs still parse — the chart itself is rendered by Argo CD, not by kustomize).
3. Open a PR. Once merged, Argo CD reconciles the new chart version. Watch `kubectl -n monitoring get pods -w` during the rollout.
4. If a CRD upgrade is part of the bump, the operator handles it transparently — but read the chart's [release notes](https://github.com/prometheus-community/helm-charts/releases) for any breaking-change callouts (major bumps occasionally rename values keys or change resource ownership).
5. If something goes wrong, revert the PR. Argo CD will roll back to the previous chart version on next reconcile.

Latest releases: <https://github.com/prometheus-community/helm-charts/releases>

---

## Troubleshooting

### `kube-prometheus-stack` Application is `OutOfSync`

See [Drift on first reconcile](#drift-on-first-reconcile) above.

### Grafana pod stuck `CrashLoopBackOff` with "invalid admin credentials"

The ExternalSecret hasn't materialized `grafana-admin-creds` yet, or the keys are wrong. Check:

```bash
kubectl -n monitoring describe externalsecret grafana-admin-creds
kubectl -n monitoring get secret grafana-admin-creds -o yaml
```

If `STATUS: SecretSyncedError`, the most common cause is that the GCP secret `grafana-admin-password` doesn't exist in `homelab-495921`. Re-run Step 1.

### A target shows `DOWN` in Prometheus

`kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` → <http://localhost:9090/targets> → click the failing target → read the "Last Error" column. Most common causes:

- The downstream Service / Pod isn't `Ready`
- The port name on the ServiceMonitor doesn't match the Service's port name
- A NetworkPolicy is blocking Prometheus → target traffic (we don't run NetworkPolicies in Phase 0, so unlikely)
- The metrics endpoint requires auth (Argo CD's metrics ports do not — they're unauthenticated by design and isolated by ClusterIP)

### Alertmanager pods stuck `Pending`

PVC binding usually. `kubectl -n monitoring describe pvc` and check the `local-path` provisioner is running (`kubectl -n kube-system get pods -l app=local-path-provisioner`).

### Want to silence everything during maintenance

Port-forward Alertmanager:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

<http://localhost:9093/#/silences> → New Silence → matcher `alertname=~".*"` for the duration you need.
