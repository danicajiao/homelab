# Node Setup

Reference documentation for the physical homelab node.

---

## Hardware

| Component   | Details |
|-------------|---------|
| Case        | Fractal Ridge Mini-ITX |
| Motherboard | Gigabyte B850I AORUS PRO (Revision 1.0) |
| CPU         | AMD Ryzen 9600X |
| RAM         | G.Skill Ripjaws S5 2x32GB DDR5-6000 CL36 (64GB total) |
| Storage     | Fanxiang S690D 2TB NVMe |
| PSU         | Corsair SF750 80 PLUS Platinum SFX Power Supply |

## BIOS

- Version: **F12a**
- fTPM reset performed after CPU swap (7600X → 9600X)
- EXPO profile: **enabled** (DDR5-6000 CL36)

## Operating System

- **Ubuntu Server 26.04 LTS**
- Kernel: 7.0.0-14-generic x86_64
- Hostname: `homelab`
- Primary user: `danicajiao`

### Storage layout

| Mount point | Size   | Type                      |
|-------------|--------|---------------------------|
| `/`         | 1.8TB  | LVM logical volume (ext4) |
| `/boot`     | 2GB    | ext4                      |
| `/boot/efi` | 1.04GB | fat32                     |

---

## Network

- Interface: `enp6s0` (ethernet)
- IP: `192.168.0.44` (DHCP)
- Config: `/etc/systemd/network/10-ethernet.network`

```ini
[Match]
Name=enp6s0

[Network]
DHCP=yes
```

> **TODO:** Set a static IP reservation in router for MAC `10:ff:e0:b1:6b:5d` to always assign `192.168.0.44`.

---

## SSH

### Server (`/etc/ssh/sshd_config`)

```
PasswordAuthentication no
PermitRootLogin no
```

### Client (`~/.ssh/config` on Mac)

```
Host homelab
  HostName 192.168.0.44
  User danicajiao
  UseKeychain yes
  AddKeysToAgent yes
  IdentityFile ~/.ssh/id_ed25519

Host homelab-ts
  HostName 100.121.57.120
  User danicajiao
  UseKeychain yes
  AddKeysToAgent yes
  IdentityFile ~/.ssh/id_ed25519
```

Use `homelab` on the local network, `homelab-ts` from anywhere via Tailscale.

### Key

| Item        | Location |
|-------------|----------|
| Private key | `~/.ssh/id_ed25519` (Mac) |
| Public key  | `~/.ssh/id_ed25519.pub` (Mac) + `~/.ssh/authorized_keys` (node) |
| Passphrase  | macOS iCloud Keychain |
| Algorithm   | ED25519 |

> **TODO:** Back up private key to encrypted USB or 1Password.

---

## Firewall (UFW)

```bash
sudo ufw status
```

| Port  | Protocol | Interface   | Purpose          |
|-------|----------|-------------|------------------|
| 22    | TCP      | Anywhere    | SSH              |
| 6443  | TCP      | tailscale0  | Kubernetes API   |
| 25565 | TCP      | Anywhere    | Minecraft Java   |

```bash
# Open a port to all interfaces
sudo ufw allow <port>/tcp

# Open a port to Tailscale only
sudo ufw allow in on tailscale0 to any port <port> proto tcp
```

---

## Kubernetes (k3s)

- **Version:** v1.34.6+k3s1
- **Type:** Single-node cluster
- **Role:** control-plane
- **Config:** `/etc/rancher/k3s/config.yaml`

```yaml
tls-san:
  - 100.121.57.120
```

The Tailscale IP is added as a TLS SAN so kubectl can connect via Tailscale without a certificate error.

### System pods

| Pod                    | Namespace   | Purpose             |
|------------------------|-------------|---------------------|
| coredns                | kube-system | DNS resolution      |
| traefik                | kube-system | Ingress controller  |
| local-path-provisioner | kube-system | Persistent storage  |
| metrics-server         | kube-system | Resource metrics    |
| svclb-traefik          | kube-system | Load balancer       |

---

## Tailscale

| Device              | Tailscale IP    |
|---------------------|-----------------|
| homelab (node)      | 100.121.57.120  |
| Daniel's MacBook Pro| 100.125.85.98   |

### Node install

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

### Mac install

Use the standalone pkg from tailscale.com/download (not Homebrew or App Store).

### iPhone / iPad install

Install the Tailscale app from the App Store and sign in with the same account.

---

## kubectl (on Mac)

### One-time setup

With Tailscale connected, pull the kubeconfig from the node and rewrite the server address:

```bash
ssh homelab-ts "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed 's/127.0.0.1/100.121.57.120/' \
  > ~/.kube/config
chmod 600 ~/.kube/config
```

This works without a password prompt because `danicajiao` has passwordless sudo configured. To set this up on a fresh node:

```bash
sudo visudo -f /etc/sudoers.d/danicajiao
```

Add:

```
danicajiao ALL=(ALL) NOPASSWD: ALL
```

### Verify

```bash
kubectl get nodes
```

Should return the `homelab` node as `Ready`.

### Notes

- `~/.kube/config` is the default kubeconfig path — no `KUBECONFIG` env var needed.
- kubectl connects to `https://100.121.57.120:6443` via Tailscale, so it works on any network.
