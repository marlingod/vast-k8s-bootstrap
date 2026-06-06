# Kubernetes Cluster Setup (Ansible)

Automated deployment of a Kubernetes cluster (kubeadm + containerd + Flannel) plus ClusterShell.

## Configuration

There are exactly two configuration files:

| Knob | File |
| --- | --- |
| Host IP addresses | `ansible/inventory.ini` |
| Credentials, K8s version, CIDR, Flannel version, SSH user | `ansible/group_vars/all.yml` |

`ansible/group_vars/all.yml` is gitignored. A committed template lives at `ansible/group_vars/all.yml.example`.

## Quick Start

```bash
# 1. Install Ansible
pip install ansible

# 2. Create your config
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
$EDITOR ansible/group_vars/all.yml   # fill in passwords

# 3. (Optional) Add or change hosts
$EDITOR ansible/inventory.ini

# 4. Deploy
cd ansible
ansible-playbook -i inventory.ini site.yml
```

Individual playbooks if you want to re-run a single step:
```bash
ansible-playbook -i inventory.ini 01-install-clush.yml
ansible-playbook -i inventory.ini 02-k8s-prerequisites.yml
ansible-playbook -i inventory.ini 03-k8s-master-init.yml
ansible-playbook -i inventory.ini 04-k8s-worker-join.yml
```

## Re-deploying onto Nodes That Already Have Kubernetes

The playbooks assume a fresh install. To redeploy onto nodes already running a cluster, reset them first:

```bash
# On every node, as root
kubeadm reset -f
rm -rf /etc/cni/net.d /var/lib/kubelet/* ~/.kube
```

Then re-run `site.yml`.

## What Gets Installed

- containerd (latest from Docker repo)
- kubeadm / kubelet / kubectl, version per `kubernetes_version` in `group_vars/all.yml` (default `1.35`)
- Flannel CNI, version per `flannel_version` (default `v0.27.4`)
- ClusterShell (`clush`) with groups: `all`, `masters`, `workers`, `k8s`

## How It Works (Brief)

`site.yml` chains four playbooks against the inventory:

1. **`01-install-clush.yml`** — installs ClusterShell on every node and writes the cluster's group/host map.
2. **`02-k8s-prerequisites.yml`** — disables swap, loads kernel modules, sets sysctl, installs containerd and the K8s packages at the version pinned in `group_vars/all.yml`.
3. **`03-k8s-master-init.yml`** — runs `kubeadm init` on the master, installs Flannel CNI, generates the worker join token, and fetches it back to the local machine.
4. **`04-k8s-worker-join.yml`** — copies the join token onto each worker and joins them.

Variables flow as: `inventory.ini` defines host IPs and group membership; `group_vars/all.yml` is auto-loaded by Ansible for every host and supplies credentials, K8s version, CIDR, Flannel version, and the SSH user. Playbooks reference both through Jinja (`{{ hostvars['master'].ansible_host }}`, `{{ ansible_user }}`, `{{ kubernetes_version }}`, etc.) — no values are hardcoded inside playbooks.

For a deeper walk-through (per-playbook task list, variable resolution order, kubeadm bootstrap flow, post-deploy node state, common change scenarios), see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Post-Installation

```bash
# Read $ansible_user / master_host from your config; use what's in inventory.ini
ssh <ansible_user>@<master_ip>
kubectl get nodes
clush -g all 'hostname'
```

## Troubleshooting

```bash
# Reset a single node
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/kubelet/* ~/.kube

# Check services on master
sudo systemctl status kubelet containerd
sudo journalctl -xeu kubelet | tail -100

# Check Flannel
kubectl get pods -n kube-flannel
```

## Prerequisites

**On your local machine:**
- Ansible (`pip install ansible`)

**On the target nodes:**
- Ubuntu 20.04/22.04/24.04 or RHEL/CentOS 7/8/Stream
- SSH access enabled, sudo for the configured `ansible_user`

## Adding a Worker

1. Add the host to `ansible/inventory.ini` under `[workers]`.
2. `ansible-playbook -i inventory.ini 02-k8s-prerequisites.yml -l new_worker`
3. `ansible-playbook -i inventory.ini 04-k8s-worker-join.yml -l new_worker`
