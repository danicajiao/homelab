# Minecraft

Fabric 1.20.1 server running the [Homestead](https://www.curseforge.com/minecraft/modpacks/homestead) modpack. Exposed on port 25565 via a router-level forward.

## Deploying

Argo CD reconciles `apps/gaming/minecraft/` from `main` automatically — the manifests in this directory are applied within ~3 minutes of merge (or immediately if you force a refresh on the root Application). Manual `kubectl apply` still works for breaking-glass scenarios but should be unusual.

> [!NOTE]
> The Application lives at [`argocd/minecraft.yaml`](../../../argocd/minecraft.yaml). It's single-source (kustomize, no upstream chart) and ignores `/spec/replicas` on the Deployment so day-to-day starts/stops via `kubectl scale` aren't reverted by selfHeal — see [Starting and stopping the server](#starting-and-stopping-the-server) below.

## Starting and stopping the server

Day-to-day on/off is `kubectl scale`. Argo CD won't revert these because `/spec/replicas` is in the Application's `ignoreDifferences` block ([`argocd/minecraft.yaml`](../../../argocd/minecraft.yaml)). Git holds the default (`replicas: 0`) so a fresh cluster bootstrap leaves the server **off** — it only runs when you manually scale it up. Once running, manual scale changes persist through Argo CD reconciles and machine restarts (K3s preserves the live state in etcd).

```bash
# Stop the server (graceful — world saves before pod exits)
kubectl scale deployment minecraft -n gaming --replicas=0

# Start the server
kubectl scale deployment minecraft -n gaming --replicas=1

# Status
kubectl get pods -n gaming -l app=minecraft
```

> [!IMPORTANT]
> A `ValidatingAdmissionPolicy` ([`replica-cap.yaml`](replica-cap.yaml)) enforces a **hard cap of 1 replica**. Attempting `--replicas=2` (or higher) is rejected at the API server — Minecraft world data is single-writer and concurrent pods on the same PVC would corrupt the world. To run more than one server, create a separate Deployment + PVC.

## Secret management

### CurseForge API key

Required for downloading extra mods via `CURSEFORGE_FILES`. The value lives in **GCP Secret Manager** (project `cove-6a685`); ESO materializes it as the K8s Secret `minecraft-secrets` with key `CF_API_KEY` via [`external-secret.yaml`](external-secret.yaml). The Deployment consumes it via `secretKeyRef` — no `kubectl create secret` needed.

To upload (or rotate) the key:

```bash
echo -n '<paste-curseforge-api-key>' | gcloud secrets create minecraft-curseforge-api-key \
    --project cove-6a685 --data-file=- --replication-policy=automatic
```

> [!IMPORTANT]
> CurseForge keys start with `$2a$10$` (a literal bcrypt prefix). **Wrap the value in single quotes** as shown — double quotes let the shell expand the `$` signs and you'd end up storing an empty value.

To rotate, replace `gcloud secrets create` with `gcloud secrets versions add minecraft-curseforge-api-key --data-file=-`. ESO picks up the new version on its next refresh (default 1h; force-sync via the `force-sync` annotation).

### Bootstrap rollout

One-time sequence the first time this lands on a cluster that already has a manually-created `minecraft-secrets`:

1. Upload the existing CF API key to GCP SM with the `gcloud secrets create` command above.
2. Delete the manually-created K8s Secret so ESO can take ownership cleanly:
   ```bash
   kubectl -n gaming delete secret minecraft-secrets
   ```
   The Minecraft pod tolerates this — it'll restart and pick up the ESO-created Secret on next pull.
3. Merge the PR. Argo CD reconciles, ESO creates `minecraft-secrets`, the Deployment rolls.
4. Verify: `kubectl -n argocd get application minecraft` → `Synced/Healthy`. `kubectl -n gaming get externalsecret minecraft-curseforge-key` → `SecretSynced`. Pod stays `Running`.

## First-time world pre-generation

Once the server is running, open an RCON session and run [Chunky](https://www.curseforge.com/minecraft/mc-mods/chunky) for each dimension:

```bash
kubectl exec -it -n gaming \
  $(kubectl get pod -n gaming -l app=minecraft -o jsonpath='{.items[0].metadata.name}') \
  -- rcon-cli
```

```
chunky radius 3000
chunky start
```

Wait for completion (`chunky status`), then repeat for the Nether and End:

```
chunky world minecraft:the_nether
chunky radius 3000
chunky start

chunky world minecraft:the_end
chunky radius 3000
chunky start
```

## Optional client mod

The server's Chunky pre-gen makes long-distance terrain available, but rendering it client-side requires Distant Horizons. The vanilla render distance still works without it.

- **Distant Horizons 3.0.2-b** for Fabric 1.20.1 — <https://modrinth.com/mod/distanthorizons>

## Related

- Top-level [homelab README](../../../README.md)
- Hardware reference: [docs/node-setup.md](../../../docs/node-setup.md)
- Common commands: [docs/commands.md](../../../docs/commands.md)
