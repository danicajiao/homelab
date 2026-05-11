# Common Commands

Quick reference for interacting with the homelab node, k3s cluster, and Minecraft server.

---

## Node

```bash
# SSH into the node
ssh homelab

# Shut down
sudo shutdown -h now

# Reboot
sudo reboot
```

---

## kubectl — Cluster

```bash
# Verify cluster is reachable
kubectl cluster-info

# List all nodes
kubectl get nodes

# List all pods across all namespaces
kubectl get pods -A

# List system pods
kubectl get pods -n kube-system

# Check resource usage (requires metrics-server)
kubectl top nodes
kubectl top pods -n gaming
```

---

## kubectl — Minecraft

```bash
# List all resources in the gaming namespace
kubectl get all -n gaming

# List PVCs
kubectl get pvc -n gaming

# Watch pod status live
kubectl get pods -n gaming -w

# Describe pod (events, init container status, etc.)
kubectl describe pod -n gaming <pod-name>

# Auto-resolve current pod name
POD=$(kubectl get pod -n gaming -l app=minecraft -o jsonpath='{.items[0].metadata.name}')
```

### Deploy

The normal flow is **git → Argo CD**: edit a manifest under `apps/gaming/minecraft/`, open a PR, merge, Argo CD reconciles within ~3 minutes. The `kubectl apply` commands below are for breaking-glass scenarios only (Argo CD down, recovering from a bad sync, etc.) and should be unusual.

```bash
# Breaking-glass only — first-time apply (two-step to avoid namespace race)
kubectl apply -f apps/gaming/minecraft/namespace.yaml && \
kubectl apply -k apps/gaming/minecraft/

# Breaking-glass only — re-apply after manifest changes
kubectl apply -k apps/gaming/minecraft/
```

### Scale (start / stop the server)

`/spec/replicas` is intentionally outside Argo CD's reconcile loop (see `ignoreDifferences` on `argocd/minecraft.yaml`), so these commands are safe day-to-day — selfHeal will not revert them. Git holds the default (`replicas: 1`) so a fresh cluster bootstrap auto-starts the server; humans hold the runtime control.

```bash
# Stop the server (graceful — world saves before pod exits)
kubectl scale deployment minecraft -n gaming --replicas=0

# Start the server
kubectl scale deployment minecraft -n gaming --replicas=1

# Status
kubectl get pods -n gaming -l app=minecraft
```

Optional shell aliases:

```bash
alias mc-stop='kubectl scale deployment minecraft -n gaming --replicas=0'
alias mc-start='kubectl scale deployment minecraft -n gaming --replicas=1'
alias mc-status='kubectl get pods -n gaming -l app=minecraft'
```

### Restart

```bash
# Rolling restart (picks up new env vars, image changes)
kubectl rollout restart deployment minecraft -n gaming
```

### Tear down

> Breaking-glass only — Argo CD will recreate anything it owns within a reconcile cycle. To actually remove the app, also delete `argocd/minecraft.yaml` (and the entry in `argocd/kustomization.yaml`) via PR.

```bash
# Delete deployment and service only (preserves PVC and world data)
kubectl delete -f apps/gaming/minecraft/deployment.yaml
kubectl delete -f apps/gaming/minecraft/service.yaml

# Delete everything including PVC (world data will be lost)
kubectl delete -k apps/gaming/minecraft/
```

---

## kubectl — Logs

```bash
# Stream live logs
kubectl logs -n gaming -l app=minecraft -f

# Logs from the last crashed container
kubectl logs -n gaming -l app=minecraft --previous

# Logs from the init container
kubectl logs -n gaming <pod-name> -c modpack-installer

# Last 100 lines
kubectl logs -n gaming -l app=minecraft --tail=100
```

---

## kubectl — Exec

```bash
# Open a shell inside the container
kubectl exec -it -n gaming $POD -- sh

# List mods
kubectl exec -it -n gaming $POD -- ls /data/mods

# View a file inside the container
kubectl exec -it -n gaming $POD -- cat /data/server.properties
```

---

## kubectl — Secrets

The `minecraft-secrets` Secret (key: `CF_API_KEY`) is materialized by ESO from GCP Secret Manager — see [`apps/gaming/minecraft/external-secret.yaml`](../apps/gaming/minecraft/external-secret.yaml). `kubectl create secret` is no longer part of the flow.

```bash
# Upload (or rotate) the CurseForge API key in GCP Secret Manager.
# Use single quotes — the key contains $ signs that the shell would expand.
echo -n '<paste-curseforge-api-key>' | gcloud secrets create minecraft-curseforge-api-key \
    --project homelab-495921 --data-file=- --replication-policy=automatic
# To rotate after the secret already exists, swap `create` for:
#   gcloud secrets versions add minecraft-curseforge-api-key --data-file=-
# ESO picks up the new version on its next refresh (default 1h).

# List secrets
kubectl get secret -n gaming

# Inspect the ExternalSecret status
kubectl get externalsecret -n gaming minecraft-curseforge-key

# Delete the materialized K8s Secret.
# ESO will immediately recreate it from GCP SM (creationPolicy: Owner). To
# actually remove it, delete the GCP secret AND the ExternalSecret manifest:
#   gcloud secrets delete minecraft-curseforge-api-key --project homelab-495921
#   # then remove apps/gaming/minecraft/external-secret.yaml via PR
kubectl delete secret minecraft-secrets -n gaming
```

---

## PVC — World Data

The world is stored in a `local-path` PVC on the node at:

```
/var/lib/rancher/k3s/storage/pvc-<id>_gaming_minecraft-data/
```

```bash
# Find the PVC directory
sudo ls /var/lib/rancher/k3s/storage/

# Browse PVC contents (requires sudo)
sudo ls -la /var/lib/rancher/k3s/storage/<pvc-dir>/

# Check mods directory permissions
sudo ls -la /var/lib/rancher/k3s/storage/<pvc-dir>/ | grep mods
```

---

## RCON

RCON lets you send server commands without being in-game.

```bash
# Open an interactive RCON session
kubectl exec -it -n gaming $POD -- rcon-cli
```

Once connected, type any Minecraft server command without the leading `/`:

```
help
list
op <username>
deop <username>
say <message>
stop
```

---

## Chunky — World Pre-generation

Chunky generates chunks ahead of time so players don't trigger lag on first visit.
Run these inside an RCON session.

```bash
# Open RCON
kubectl exec -it -n gaming $POD -- rcon-cli
```

```
# Overworld (default world)
chunky radius 3000
chunky start

# Check progress
chunky status

# Nether
chunky world minecraft:the_nether
chunky radius 3000
chunky start

# The End
chunky world minecraft:the_end
chunky radius 3000
chunky start

# Cancel a running job
chunky cancel
```

> Wait for each world to finish before starting the next.
> Chunky generates in a spiral from the center (0,0) outward.

---

## kubectl — Monitoring (Prometheus / Grafana / Alertmanager)

```bash
# Application + pod status
kubectl -n argocd get application kube-prometheus-stack
kubectl -n monitoring get pods

# Inspect ServiceMonitors / PodMonitors / PrometheusRules cluster-wide
kubectl get servicemonitors -A
kubectl get podmonitors -A
kubectl get prometheusrules -A
```

### Grafana

```bash
# Port-forward Grafana UI (http://localhost:3000)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# Recover the admin password (synced from GCP SM)
kubectl -n monitoring get secret grafana-admin-creds \
    -o jsonpath='{.data.admin-password}' | base64 -d

# Or fetch directly from GCP SM
gcloud secrets versions access latest \
    --secret=grafana-admin-password \
    --project=homelab-495921
```

Login: `admin` + the password above.

### Prometheus

```bash
# Port-forward Prometheus UI (http://localhost:9090)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

# Targets:    http://localhost:9090/targets
# Alerts:     http://localhost:9090/alerts
# Rules:      http://localhost:9090/rules
# PromQL UI:  http://localhost:9090/graph
```

Common PromQL starting points:

```promql
# Pod count per namespace
count by (namespace) (kube_pod_info)

# Pod memory usage (MiB) per pod in cove namespaces
sum by (pod) (container_memory_working_set_bytes{namespace=~"cove-.*"}) / 1024 / 1024

# Node CPU usage %
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Disk usage % per filesystem
100 - ((node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100)

# Pods that have restarted in the last hour
increase(kube_pod_container_status_restarts_total[1h]) > 0
```

### Alertmanager

```bash
# Port-forward Alertmanager UI (http://localhost:9093)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093

# Silences: http://localhost:9093/#/silences
# Alerts:   http://localhost:9093/#/alerts
```

### Force a Prometheus / Grafana / Alertmanager restart

```bash
kubectl -n monitoring rollout restart statefulset prometheus-kube-prometheus-stack-prometheus
kubectl -n monitoring rollout restart statefulset alertmanager-kube-prometheus-stack-alertmanager
kubectl -n monitoring rollout restart statefulset kube-prometheus-stack-grafana
```

Full runbook: [docs/kube-prometheus-stack-install.md](kube-prometheus-stack-install.md).

---

## kubectl — Logs (Loki / Alloy)

```bash
# Application + pod status
kubectl -n argocd get application loki alloy
kubectl -n monitoring get pods -l 'app.kubernetes.io/name in (loki,alloy)'

# Check the Garage credentials are synced
kubectl -n monitoring get externalsecret loki-creds

# Loki self-health
kubectl -n monitoring port-forward svc/loki 3100:3100
# http://localhost:3100/ready    → "ready"
# http://localhost:3100/metrics  → loki_* metrics

# Alloy UI (per-pod, on port 12345). Components view shows targets +
# lines forwarded per pipeline stage.
kubectl -n monitoring port-forward ds/alloy 12345:12345
# http://localhost:12345
```

### LogQL — querying logs

Grafana → Explore → switch the datasource picker (top-left) to `Loki`. The label set Alloy applies to every stream: `namespace`, `pod`, `container`, `app`, `node`.

```logql
# All logs from a namespace
{namespace="argocd"}

# All logs from one pod (exact name)
{namespace="argocd", pod="argocd-server-7c9f8c8c8c-abcde"}

# All logs from pods matching an app label
{namespace="gaming", app="minecraft"}

# All logs from a node
{node="homelab"}

# Label match + text search (case-insensitive)
{namespace="garage"} |~ "(?i)error|fail|panic"

# Parse JSON log lines (one field per parsed key)
{namespace="cnpg-system"} | json

# Top talkers — log line count per pod, last 5m
sum by (pod) (count_over_time({namespace="monitoring"}[5m]))

# Error rate per namespace, last 1m
sum by (namespace) (rate({namespace=~".+"} |~ "(?i)error|fail|panic"[1m]))

# Lines from the last 15m that contain a specific string, formatted
{namespace="argocd"} |= "OutOfSync" | line_format "{{.pod}}: {{__line__}}"
```

Full runbook: [docs/loki-install.md](loki-install.md).

---

## k3s — Service Management

```bash
# Check k3s service status
sudo systemctl status k3s

# Restart k3s
sudo systemctl restart k3s

# View k3s logs
sudo journalctl -u k3s -f
```
