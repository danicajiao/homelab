# homelab

GitOps repository for a single-node k3s homelab cluster.

**Node:** AMD Ryzen 9600X, 64 GB RAM  
**Storage:** k3s built-in `local-path` provisioner  
**Exposed port:** 25565 (router port forward)

| Doc | Purpose |
|-----|---------|
| [docs/node-setup.md](docs/node-setup.md) | Hardware, OS, network, SSH, firewall, k3s reference |
| [docs/commands.md](docs/commands.md) | Common commands for node, k3s, Minecraft, RCON, Chunky |

---

## Repository layout

```
homelab/
├── apps/
│   └── gaming/
│       └── minecraft/      ← Homestead modpack (Fabric 1.20.1)
├── docs/
│   ├── node-setup.md
│   └── commands.md
└── infra/                  ← cert-manager, ingress-nginx, etc. (future)
```

---

## Deploying Minecraft

The deploy workflow is triggered manually from the Actions tab:

> **Actions → Deploy Minecraft → Run workflow**

Or locally with `kubectl` pointed at the cluster:

```bash
kubectl apply -f apps/gaming/minecraft/namespace.yaml && \
kubectl apply -f apps/gaming/minecraft/
```

> [!NOTE]
> The two-step apply is necessary because the `gaming` namespace must exist
> before the deployment, PVC, and service can be created.

### Add the KUBECONFIG secret (one-time)

The workflow authenticates to k3s via a kubeconfig stored as a GitHub Actions secret.

> [!NOTE]
> The deploy workflow uses a GitHub-hosted runner, so the kubeconfig must point
> to a publicly reachable API server endpoint — not `127.0.0.1`. Set up a tunnel
> (Tailscale, Cloudflare Tunnel) or forward port 6443 on your router before
> wiring this up.

```bash
# On the node, grab the kubeconfig k3s generates:
sudo cat /etc/rancher/k3s/k3s.yaml
```

Update the `server:` field to your public endpoint, then add it in GitHub:

> **Repo → Settings → Secrets and variables → Actions → New repository secret**  
> Name: `KUBECONFIG`  
> Value: _(paste the edited k3s.yaml contents)_

### Add the CurseForge API key secret (one-time)

Required for downloading extra mods via `CURSEFORGE_FILES`:

```bash
kubectl create secret generic minecraft-secrets \
  --from-literal=CF_API_KEY='$2a$10$your-key-here' \
  -n gaming
```

> [!IMPORTANT]
> Use single quotes around the key value — CurseForge keys start with `$2a$10$`
> and double quotes will cause the shell to expand the `$` signs, storing an empty value.

### First-time world pre-generation

Once the server is running, open an RCON session and run Chunky for each dimension:

```bash
kubectl exec -it -n gaming $(kubectl get pod -n gaming -l app=minecraft -o jsonpath='{.items[0].metadata.name}') -- rcon-cli
```

```
chunky radius 3000
chunky start
```

Wait for completion (`chunky status`), then repeat for other dimensions:

```
chunky world minecraft:the_nether
chunky radius 3000
chunky start

chunky world minecraft:the_end
chunky radius 3000
chunky start
```

### Client setup — Distant Horizons

Each player must install the matching client mod:

- **Distant Horizons 3.0.2-b** for Fabric 1.20.1 — <https://modrinth.com/mod/distanthorizons>

---

## Secrets policy

- **Never commit** `*.env` files or `secrets.yaml` — both are in `.gitignore`.
- Cluster credentials belong in **GitHub Secrets** or `kubectl` secrets only.
- Future API keys (CurseForge, CDN, etc.) follow the same rule.
