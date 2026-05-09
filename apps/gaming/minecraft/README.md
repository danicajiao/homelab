# Minecraft

Fabric 1.20.1 server running the [Homestead](https://www.curseforge.com/minecraft/modpacks/homestead) modpack. Exposed on port 25565 via a router-level forward.

> [!NOTE]
> This deploy uses a legacy GitHub Actions workflow ([`.github/workflows/deploy.yml`](../../../.github/workflows/deploy.yml)) that predates the Argo CD setup. Migrating it to a `cove`-style Argo CD Application is a small future task — not currently tracked.

## Deploying

The deploy workflow is triggered manually:

> **Repo → Actions → Deploy Minecraft → Run workflow**

Or locally with `kubectl` pointed at the cluster:

```bash
kubectl apply -f apps/gaming/minecraft/namespace.yaml && \
kubectl apply -f apps/gaming/minecraft/
```

> [!NOTE]
> The two-step apply is necessary because the `gaming` namespace must exist before the deployment, PVC, and service can be created.

## One-time setup

### KUBECONFIG GitHub secret

The workflow authenticates to K3s via a kubeconfig stored as a GitHub Actions secret.

> [!NOTE]
> The deploy workflow uses a GitHub-hosted runner, so the kubeconfig must point to a publicly reachable API server endpoint — not `127.0.0.1`. Set up a tunnel (Tailscale, Cloudflare Tunnel) or forward port 6443 on your router before wiring this up.

```bash
# On the node, grab the kubeconfig K3s generates:
sudo cat /etc/rancher/k3s/k3s.yaml
```

Update the `server:` field to your public endpoint, then add it in GitHub:

> **Repo → Settings → Secrets and variables → Actions → New repository secret**
> Name: `KUBECONFIG`
> Value: _(paste the edited k3s.yaml contents)_

### CurseForge API key

Required for downloading extra mods via `CURSEFORGE_FILES`:

```bash
kubectl create secret generic minecraft-secrets \
  --from-literal=CF_API_KEY='$2a$10$your-key-here' \
  -n gaming
```

> [!IMPORTANT]
> Use single quotes around the key value — CurseForge keys start with `$2a$10$` and double quotes will cause the shell to expand the `$` signs, storing an empty value.

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

## Client requirement

Each player must install the matching client mod:

- **Distant Horizons 3.0.2-b** for Fabric 1.20.1 — <https://modrinth.com/mod/distanthorizons>

## Related

- Top-level [homelab README](../../../README.md)
- Hardware reference: [docs/node-setup.md](../../../docs/node-setup.md)
- Common commands: [docs/commands.md](../../../docs/commands.md)
