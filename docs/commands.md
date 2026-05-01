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

```bash
# First-time deploy (two-step to avoid namespace race condition)
kubectl apply -f apps/gaming/minecraft/namespace.yaml && \
kubectl apply -f apps/gaming/minecraft/

# Re-apply after manifest changes
kubectl apply -f apps/gaming/minecraft/

# Re-apply a single file
kubectl apply -f apps/gaming/minecraft/deployment.yaml
```

### Scale

```bash
# Stop the server (graceful — world saves before pod exits)
kubectl scale deployment minecraft -n gaming --replicas=0

# Start the server
kubectl scale deployment minecraft -n gaming --replicas=1
```

### Restart

```bash
# Rolling restart (picks up new env vars, image changes)
kubectl rollout restart deployment minecraft -n gaming
```

### Tear down

```bash
# Delete deployment and service only (preserves PVC and world data)
kubectl delete -f apps/gaming/minecraft/deployment.yaml
kubectl delete -f apps/gaming/minecraft/service.yaml

# Delete everything including PVC (world data will be lost)
kubectl delete -f apps/gaming/minecraft/
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

```bash
# Create the CurseForge API key secret
# Use single quotes — the key contains $ signs that the shell would expand
kubectl create secret generic minecraft-secrets \
  --from-literal=CF_API_KEY='your-key-here' \
  -n gaming

# List secrets
kubectl get secret -n gaming

# Delete a secret
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

## k3s — Service Management

```bash
# Check k3s service status
sudo systemctl status k3s

# Restart k3s
sudo systemctl restart k3s

# View k3s logs
sudo journalctl -u k3s -f
```
