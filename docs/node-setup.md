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
```

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

| Port  | Protocol | Purpose          |
|-------|----------|------------------|
| 22    | TCP      | SSH              |
| 6443  | TCP      | Kubernetes API   |
| 25565 | TCP      | Minecraft Java   |

```bash
sudo ufw allow <port>/<protocol>
```

---

## Kubernetes (k3s)

- **Version:** v1.34.6+k3s1
- **Type:** Single-node cluster
- **Role:** control-plane

### System pods

| Pod                    | Namespace   | Purpose             |
|------------------------|-------------|---------------------|
| coredns                | kube-system | DNS resolution      |
| traefik                | kube-system | Ingress controller  |
| local-path-provisioner | kube-system | Persistent storage  |
| metrics-server         | kube-system | Resource metrics    |
| svclb-traefik          | kube-system | Load balancer       |

### kubeconfig (on the node)

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

See the main [README](../README.md) for how to set up `kubectl` on your Mac.
