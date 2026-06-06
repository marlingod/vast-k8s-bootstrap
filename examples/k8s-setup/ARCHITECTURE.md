# Architecture

A walk-through of how this Ansible-based Kubernetes setup is wired. Pair this document with `README.md` (which covers operational usage).

## Goals That Shaped the Design

1. **Single source of truth for every kind of config.** A node IP appears in exactly one file (`inventory.ini`). The password appears in exactly one file (`group_vars/all.yml`). Same for K8s version, Flannel version, CIDR, and SSH user.
2. **Idempotent re-runs.** Re-running `site.yml` against a half-deployed cluster should converge to the same state, not duplicate work or fail.
3. **No plaintext secrets in git.** `group_vars/all.yml` holds the password but is `.gitignored`; a committed `all.yml.example` template ships in its place.

## File Map

```
k8s-setup/
├── README.md                              # operational usage
├── ARCHITECTURE.md                        # this document
├── .gitignore                             # excludes all.yml and fetched tokens
├── docs/superpowers/
│   ├── specs/2026-05-28-*.md              # design spec (why we did it this way)
│   └── plans/2026-05-28-*.md              # implementation plan
└── ansible/
    ├── ansible.cfg                        # connection defaults
    ├── inventory.ini                      # hosts + IPs (only)
    ├── group_vars/
    │   ├── all.yml                        # gitignored; real creds + versions
    │   └── all.yml.example                # committed template
    ├── site.yml                           # master playbook (imports the 4 below)
    ├── 01-install-clush.yml
    ├── 02-k8s-prerequisites.yml
    ├── 03-k8s-master-init.yml
    └── 04-k8s-worker-join.yml
```

## The Two-File Configuration Model

Ansible inventory files (`inventory.ini`) do not support Jinja substitution. That forces a choice: either keep everything in inventory (with the duplication that comes from it), or split by what each file is naturally good at. We chose the split.

| Knob | Lives in | Why |
| --- | --- | --- |
| Host IP addresses, group membership | `inventory.ini` | Inventory is the canonical Ansible location for hostnames/IPs. |
| `ansible_user`, `ansible_password`, `ansible_become_password` | `group_vars/all.yml` | Single secrets file, gitignored. |
| `kubernetes_version`, `flannel_version`, `pod_network_cidr` | `group_vars/all.yml` | Co-located with the other tunables you change per cluster. |

`group_vars/all.yml` is automatically loaded by Ansible for every host in the `all` group (which, by definition, is every host). That is why no inventory entry needs to reference it.

## How Variables Resolve at Run Time

When Ansible runs against host `master`, it merges variables from several sources. The effective hostvars for `master` are:

```
ansible_host:            10.143.2.65            # from inventory.ini
ansible_user:            vastdata               # from group_vars/all.yml
ansible_password:        vastdata               # from group_vars/all.yml
ansible_become_password: vastdata               # from group_vars/all.yml
kubernetes_version:      "1.35"                 # from group_vars/all.yml
pod_network_cidr:        "10.244.0.0/16"        # from group_vars/all.yml
flannel_version:         "v0.27.4"              # from group_vars/all.yml
ansible_become:          yes                    # from inventory.ini [all:vars]
ansible_ssh_common_args: ...                    # from inventory.ini [all:vars]
ansible_python_interpreter: /usr/bin/python3    # from inventory.ini [all:vars]
```

You can inspect this yourself with:

```bash
cd ansible
ansible-inventory -i inventory.ini --list
```

Precedence order (lowest to highest): role defaults → inventory file vars → `group_vars/all` → `group_vars/<group>` → `host_vars/<host>` → play `vars:` → extra-vars (`-e`). Nothing in this project uses anything higher than `group_vars/all`, so what you see is what you get.

## What Each Playbook Does

### `01-install-clush.yml`

Runs against `hosts: all`. Installs ClusterShell from the OS package repo (apt or yum + EPEL), then writes two config files on every node:

- `/etc/clustershell/groups.d/local.cfg` — defines the `all`, `masters`, `workers`, `k8s` groups and maps `master` / `worker1` to their IPs. Both IPs are templated from `{{ hostvars['master'].ansible_host }}` / `{{ hostvars['worker1'].ansible_host }}`.
- `/etc/clustershell/clush.conf` — sets SSH defaults including `ssh_user: {{ ansible_user }}`.

After this runs, you can `ssh vastdata@<master>` and `clush -g all 'hostname'` to fan out.

### `02-k8s-prerequisites.yml`

Runs against `hosts: all`. Brings every node to a kubeadm-ready state. The tasks in order:

1. **Disable swap.** Both `swapoff -a` (running state) and `lineinfile` on `/etc/fstab` (persistent).
2. **Load kernel modules** `overlay` and `br_netfilter`. Written to `/etc/modules-load.d/k8s.conf` so they load on boot.
3. **Set sysctl** for `net.bridge.bridge-nf-call-iptables`, `net.bridge.bridge-nf-call-ip6tables`, `net.ipv4.ip_forward`. Written to `/etc/sysctl.d/k8s.conf`.
4. **Install containerd** from the Docker upstream repo (`containerd.io` package). Generate the default config with `containerd config default > /etc/containerd/config.toml`, then flip `SystemdCgroup = true` for the Kubelet cgroup driver alignment.
5. **Install `kubeadm`, `kubelet`, `kubectl`** from `https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_version }}/...`. The repo URL is templated from `group_vars/all.yml`, so changing one line changes which K8s minor every node installs.
6. **Open firewall ports** on masters (`6443`, `2379-2380`, `10250`, `10259`, `10257`) and workers (`10250`, `30000-32767`) if `firewalld` or `ufw` is active.

This playbook is idempotent: re-running it is a no-op once the desired state is in place.

### `03-k8s-master-init.yml`

Runs against `hosts: masters`. Bootstraps the control plane.

1. **Check if already initialized** by `stat`-ing `/etc/kubernetes/admin.conf`. If it exists, skip the `kubeadm init` step (this is the idempotency gate).
2. **Run `kubeadm init`** with `--apiserver-advertise-address={{ hostvars[inventory_hostname].ansible_host }}` (the inventory IP — deterministic) and `--pod-network-cidr={{ pod_network_cidr }}`.
3. **Install kubeconfig** for both root (`/root/.kube/config`) and the SSH user (`/home/{{ ansible_user }}/.kube/config`). Owner/group set to `{{ ansible_user }}` for the user copy.
4. **Apply Flannel CNI** from `https://github.com/flannel-io/flannel/releases/download/{{ flannel_version }}/kube-flannel.yml`. Pinned version, not `releases/latest/`, so the deploy is reproducible.
5. **Wait for Flannel pods** to be `Ready` (with retries).
6. **Generate a worker join command** via `kubeadm token create --print-join-command`. Save it to `/home/{{ ansible_user }}/k8s-join-command.sh` on the master, then `fetch` it back to the local control machine at `./k8s-join-command.sh` so the next playbook can use it.

### `04-k8s-worker-join.yml`

Runs against `hosts: workers`, then re-runs a verification play against `hosts: masters`.

For each worker:

1. **Check if already joined** by `stat`-ing `/etc/kubernetes/kubelet.conf`. Skip if it exists.
2. **Copy** the join command file from the local machine to `/tmp/` on the worker.
3. **Execute it** — the worker contacts the API server, presents the token, and the API server issues node certs.
4. **Clean up** the token file from `/tmp/`.

Then on the master:

5. **Wait** for all nodes to report `Ready`.
6. **Print** the final `kubectl get nodes -o wide` and `kubectl get pods -A`.

## End-to-End Bootstrap Flow

```
Local machine                Master (10.143.2.65)              Worker1 (10.143.2.69)
─────────────                ─────────────────────             ─────────────────────
ansible-playbook
  site.yml
     │
     ├─► 01: install clush ──┬─► apt/yum install ────────────► apt/yum install
     │                       │
     │                       └─► write clush configs ────────► write clush configs
     │
     ├─► 02: prerequisites ──┬─► swap off, modules,           swap off, modules,
     │                       │   sysctl, containerd,          sysctl, containerd,
     │                       │   kubeadm/kubelet/kubectl ───► kubeadm/kubelet/kubectl
     │                       │
     │                       └─► firewall rules               firewall rules
     │
     ├─► 03: master init ────► kubeadm init
     │                          ├─► /etc/kubernetes/admin.conf
     │                          ├─► /home/vastdata/.kube/config
     │                          ├─► kubectl apply Flannel
     │                          └─► generate join token
     │                                      │
     │  ◄───── fetch k8s-join-command.sh ───┘
     │
     └─► 04: worker join ───────────────────────────────────► kubeadm join
                                                                ├─► /etc/kubernetes/kubelet.conf
                                                                └─► node certs

Final verify on master: kubectl wait --for=condition=ready node --all
```

## State on the Nodes After a Successful Deploy

**On the master:**

| Path | What it is |
| --- | --- |
| `/etc/kubernetes/admin.conf` | The cluster-admin kubeconfig. Owned by root. |
| `/etc/kubernetes/manifests/` | Static pod manifests for API server, controller-manager, scheduler, etcd. |
| `/etc/kubernetes/pki/` | Cluster CA and component certs. |
| `/root/.kube/config` | Copy of `admin.conf` for root. |
| `/home/{{ ansible_user }}/.kube/config` | Copy of `admin.conf` for the SSH user. |
| `/home/{{ ansible_user }}/k8s-join-command.sh` | Join command + token for workers. |
| `/etc/clustershell/groups.d/local.cfg` | clush group definitions. |
| `/var/lib/containerd/` | Container runtime state. |
| `/var/lib/kubelet/` | kubelet state. |
| `/var/lib/etcd/` | etcd database (the entire cluster state). |

**On each worker:**

| Path | What it is |
| --- | --- |
| `/etc/kubernetes/kubelet.conf` | The bootstrap kubeconfig used by kubelet to talk to the API server. Presence of this file means "joined". |
| `/etc/kubernetes/pki/ca.crt` | The cluster CA cert (so the worker can verify the API server). |
| `/var/lib/kubelet/` | kubelet state, pod logs, configmap mounts, etc. |
| `/var/lib/containerd/` | Container runtime state. |
| `/etc/clustershell/groups.d/local.cfg` | clush group definitions (same as master). |

**On the local control machine:**

| Path | What it is |
| --- | --- |
| `ansible/k8s-join-command.sh` | Fetched from the master during deploy. Contains a token; gitignored. |

## Common Change Scenarios

### Change a node IP

Edit `ansible/inventory.ini`, change the `ansible_host=...` value for the affected host. No other file references that IP — `clush.conf`, `--apiserver-advertise-address`, and everything else resolve through `hostvars[].ansible_host`. Then redeploy (full reset required if the master IP changed because cluster certs are bound to the IP).

### Bump Kubernetes

Edit `ansible/group_vars/all.yml`, change `kubernetes_version: "1.35"` to the new minor. apt/yum will install the latest patch of that minor on next deploy. This playbook does NOT perform in-place upgrades of a running cluster — for that, `kubeadm upgrade plan` is the right tool. For an existing cluster, run `kubeadm reset -f` on every node first, then re-run `site.yml` for a clean install at the new version.

### Rotate the SSH/sudo password

Edit `ansible/group_vars/all.yml`, change `ansible_password` and `ansible_become_password`. Make sure the corresponding system password on the target nodes is also changed. Nothing in the playbooks needs to be rebuilt.

### Add a worker

1. Append the new host under `[workers]` in `ansible/inventory.ini`: `worker2 ansible_host=10.143.2.70`.
2. Add `worker2` to the comma-list inside the `local.cfg` heredoc in `01-install-clush.yml` (the `all:` and `workers:` lines), and add a `worker2: {{ hostvars['worker2'].ansible_host }}` alias.
3. Run prerequisites and join only against the new host:
   ```bash
   ansible-playbook -i inventory.ini 02-k8s-prerequisites.yml -l worker2
   ansible-playbook -i inventory.ini 04-k8s-worker-join.yml -l worker2
   ```

### Switch CNI from Flannel to something else (e.g., Calico)

Two edits in `03-k8s-master-init.yml`:

1. Replace the `Install Flannel CNI` task's `kubectl apply -f https://github.com/flannel-io/flannel/releases/download/{{ flannel_version }}/kube-flannel.yml` with the new CNI's manifest URL.
2. Update the `Wait for Flannel pods to be ready` task selector from `-l app=flannel -n kube-flannel` to the new CNI's namespace/label.

Also reconsider `pod_network_cidr` — Calico's default differs from Flannel's `10.244.0.0/16`.

## Why Certain Choices

**Why `hostvars[inventory_hostname].ansible_host` instead of `ansible_default_ipv4.address` for the master advertise address?**

`ansible_default_ipv4.address` is whatever NIC the OS lists first. On a multi-homed machine this can pick the wrong one — e.g., a management interface instead of the cluster network. Using the inventory value pins the address to what you declared.

**Why drop `--ignore-preflight-errors=all`?**

That flag silences real failures: swap not off, kernel modules missing, ports already in use. The original playbook used it to make first runs "just work", but at the cost of letting broken nodes through. We'd rather kubeadm fail loudly so the root cause surfaces.

**Why pin Flannel to a version?**

`releases/latest/download/` was prone to breaking the deploy whenever Flannel pushed a release. `v0.27.4` is a known-good tag for K8s 1.30+.

**Why no Ansible Vault?**

Considered and deferred. The gitignored-plaintext approach is one less ceremony at every `ansible-playbook` invocation and was sufficient for this project's threat model. A migration to Vault is a clean upgrade path: encrypt `ansible_password` and `ansible_become_password` with `ansible-vault encrypt_string`, drop `--vault-password-file ~/.vault_pass` into `ansible.cfg`. No playbook changes needed.

**Why containerd from Docker's repo and not the distro's?**

Docker's repo provides a more current `containerd.io` package than most distros' base repos, which matters because newer K8s versions occasionally require newer containerd CRI features.
