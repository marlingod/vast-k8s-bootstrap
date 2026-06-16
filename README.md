# vast.kubernetes

Ansible collection that bootstraps a kubeadm Kubernetes cluster, installs the
VAST CSI driver, and deploys the VAST DataEngine via Zarf — plus bash scripts
for K8s user provisioning when an Ansible controller isn't available.

**Status:** Verified end-to-end against a live 1.35 cluster with `make check`
(82 tasks on master, 32 on worker, 0 failures). See [Verification](#verification).

## Before you start — VAST-side prerequisites

This repo handles the K8s + Ansible plumbing only. **Several prerequisites
on the VAST cluster side are not automated** and must be done first by
following the VAST KB documentation linked below.

### 1. VAST CSI Driver prerequisites

Before running `make csi`, complete the VAST-side prep documented in:

> 📘 **[Steps to Deploy VAST CSI Driver](https://kb.vastdata.com/documentation/docs/steps-to-deploy-vast-csi-driver)**

In particular, on the VAST cluster you need:

- A **VMS user / API token** with rights to create file systems, VIP pools,
  view policies, snapshots, and quotas. The token (or username + password)
  is what you put under `vault_vms_token` / `vault_vms_username` /
  `vault_vms_password` in `inventory/group_vars/all/vault.yml`.
- A **VIP pool** (or VIP pool FQDN) for NFS mounts.
- A **view policy** and storage path the CSI driver can provision under.
- The endpoint hostname/IP of the VMS — goes in `vms_endpoint` in
  `inventory/group_vars/all/vars.yml`.

Mirror those values into `storage_classes:` in `vars.yml` (one entry per
StorageClass you want this collection to render into the rendered
`values.yaml` Helm input).

### 2. VAST DataEngine prerequisites

Before running `make zarf`, complete the VAST-side prep documented in:

> 📘 **[Enabling Data Engine on a VAST Cluster Tenant — Establish Prerequisite External Services](https://kb.vastdata.com/documentation/docs/enabling-data-engine-on-a-vast-cluster-tenant-1#establish-prerequisite-external-services)**

This is mandatory — the playbook does **not** provision the VAST tenant,
S3 view policy, NATS access, or Kafka brokers on the VAST side. You will:

- **Obtain the two `.tar.zst` Zarf packages from your VAST SE.** They are
  not in any public release feed:
  - `zarf-init-amd64-v<VERSION>.tar.zst`
  - `zarf-package-dataengine-amd64-<VERSION>.tar.zst`
- **Drop them in a local directory on this machine** (the operator's Mac
  or Linux box, not the K8s master). Default expected paths are in
  `inventory/group_vars/all/vars.yml` under `zarf_packages.operator_*_path`:
  ```yaml
  zarf_packages:
    source: upload                              # operator → master scp
    dir: "/home/{{ ansible_user }}/vast-zarf-packages"
    operator_init_path: /Users/<you>/Documents/vast/dataengine/packages/zarf-init-amd64-v0.60.0.tar.zst
    operator_dataengine_path: /Users/<you>/Documents/vast/dataengine/packages/zarf-package-dataengine-amd64-1.0.0.tar.zst
  ```
  The `zarf_packages` role scp's them to `zarf_packages.dir` on the master
  before `zarf init` / `zarf package deploy` consume them.
- **Set up the prerequisite external services** described in the KB doc
  (tenant, S3 access, NATS, network policies, etc.) so the DataEngine
  workloads have somewhere to land.

### 3. K8s cluster prerequisites

The `k8s_cluster.yml` playbook assumes vanilla VMs (Debian/Ubuntu/RHEL) with:

- SSH reachable from this machine (Ansible control node).
- A sudo-capable user (default `vastdata`) on every node.
- Outbound HTTPS to `pkgs.k8s.io`, `download.docker.com`, GitHub releases
  for Flannel and external-snapshotter CRDs (unless you run air-gapped, in
  which case mirror those or use the `local` source mode where supported).
- Kubernetes ≥ 1.33 if you already have a cluster (hard floor).

If you already have a healthy cluster (the common case at VAST customer
sites), skip `make k8s` entirely — `make csi` and `make zarf` will run
against whatever cluster `inventory/group_vars/all/vault.yml`'s kubeconfig
on the master points at.

## Layout

```
kubernetes/
├── Makefile                                # entry points: make k8s|csi|zarf|user|site|test|lint|check
├── ansible.cfg                             # collections_path, vault_password_file, fact cache
├── inventory/
│   ├── hosts.ini                           # ONE inventory for everything (tracked, you edit)
│   ├── localhost.ini                       # offline test stub (used by `make test`)
│   └── group_vars/all/
│       ├── vars.yml.example                # tracked — schema source of truth
│       ├── vars.yml                        # GITIGNORED — your cluster config (made by `make bootstrap`)
│       ├── vault.yml.example               # tracked — vault template with placeholders
│       └── vault.yml                       # GITIGNORED — ansible-vault encrypted secrets
├── requirements.yml                        # kubernetes.core, community.general, community.crypto, ansible.posix
├── requirements.txt                        # ansible, ansible-lint, kubernetes, ...
├── .ansible-lint .yamllint .pre-commit-config.yaml
├── collections/ansible_collections/vast/kubernetes/
│   ├── galaxy.yml
│   ├── playbooks/{site,k8s_cluster,csi,zarf,users}.yml   # thin orchestrators
│   └── roles/                              # 19 reusable roles (see Role catalog)
├── user-setup/                             # bash flow for environments without Ansible
└── docs/{k8s-setup,csi,zarf,user-setup}.md
```

`vars.yml` and `vault.yml` are **gitignored** — `git pull` never touches
them. Schema updates from upstream appear in `*.example`; you `diff` and
merge what you want on your own schedule.

## Requirements

- **Ansible** ≥ 2.15 (`ansible-core`) on the control machine
- **Python** ≥ 3.10 with `pip3`
- **Kubernetes target** ≥ 1.33 (hard-asserted by the `kubeadm_install` role; default is 1.35)
- **SSH + sudo** to every node in `inventory/hosts.ini`
- For lint/test targets: `ansible-lint`, `yamllint`, `shellcheck`

## Quick start

```bash
# 1. Install everything into a project-local virtualenv (.venv/) AND
#    bootstrap your local vars.yml + vault.yml from the *.example templates.
#    NEVER touches your system Python. Other Python projects on the same
#    machine keep their pinned versions of pyyaml, aiohttp, fastapi, etc.
make install
#   creates  .venv/                                          # Python virtualenv
#   creates  inventory/group_vars/all/vars.yml               # ← your cluster config (gitignored)
#   creates  inventory/group_vars/all/vault.yml              # ← your secrets (gitignored)
#   pip-installs  requirements.txt                           # ansible, ansible-lint, kubernetes, ...
#   galaxy-installs  requirements.yml                        # kubernetes.core, community.general, ...
#   into  collections/ansible_collections/                   # local to this repo
#
# Note: `make install` is a combination of `make bootstrap` (the file
# scaffolding) + `make venv` + dep install. To redo just the bootstrap
# step (safely re-running if the live files don't exist yet), use
# `make bootstrap` on its own.

# (Optional) activate the venv so `ansible`, `ansible-playbook`, `ansible-lint`
# resolve from .venv/bin/ in your shell. Not required if you only use `make ...`
# targets — they auto-detect .venv/.
source .venv/bin/activate

# 2. Initialize the vault password file (one-time per machine)
mkdir -p ~/.config/vast-kubernetes
chmod 700 ~/.config/vast-kubernetes
echo '<your-real-password>' > ~/.config/vast-kubernetes/vault_pass
chmod 600 ~/.config/vast-kubernetes/vault_pass

# 3. Fill in your secrets and encrypt (one-time per repo)
$EDITOR inventory/group_vars/all/vault.yml             # fill in real secrets
make vault-encrypt                                     # ONE-TIME first encryption
# From now on:
#   make vault-edit                                    # opens decrypted in $EDITOR, re-encrypts on save
#   make vault-rekey                                   # rotates the vault password

# 4. Edit hosts + cluster-specific config (see "Configure for your cluster" below)
$EDITOR inventory/hosts.ini
$EDITOR inventory/group_vars/all/vars.yml

# 5. Verify before any real run (read-only)
make ping                                # SSH + sudo proof on every host
make check                               # full dry-run with diffs, no mutations

# 6. Run a phase
make k8s                                 # bootstrap kubeadm cluster
make csi                                 # install VAST CSI driver
make zarf                                # deploy VAST DataEngine
make user                                # provision K8s users → ~/.kube/<name>.yaml

# or all of them in order:
make site

# 7. Idempotency check
make site                                # second run should report changed=0
```

### What `make user` produces

For every entry in the `users:` list in `vars.yml`, `make user` lands files
on **your Mac** (never on the cluster nodes — the private key never leaves
this laptop):

```
~/.kube/
├── <name>-certs/                        # only created for auth: cert
│   ├── client.key      0600             # ← private key, NEVER leaves this Mac
│   ├── client.csr      0600
│   ├── client.pem      0644             # signed client cert
│   └── ca.pem          0644             # cluster CA
└── <name>.yaml         0600             # the kubeconfig (self-contained, base64-embedded)
```

Use it:

```bash
KUBECONFIG=~/.kube/<name>.yaml kubectl auth whoami        # → User: <name>
KUBECONFIG=~/.kube/<name>.yaml kubectl get nodes
```

The default `users:` entry in `vars.yml` provisions one cluster-admin user
named `k8s-admin` with X.509 cert auth (365-day expiry). Edit the list to
rename, change role, add more entries.

## Configure for your cluster

Two files hold every per-cluster setting. Both live under `inventory/group_vars/all/`.

### A. `inventory/hosts.ini` — your nodes

```ini
[masters]
master ansible_host=10.143.2.26              # ← your master IP

[workers]
worker1 ansible_host=10.143.2.174            # ← your worker IP(s)
# worker2 ansible_host=...
```

The rest of the inventory (`[csi_controller]`, `[zarf_controller]`, etc.)
references those host aliases — you usually don't touch it.

### B. `inventory/group_vars/all/vars.yml` — non-secret config

The file is divided into five sections. Edit only what applies to your install.

#### B1. K8s cluster (skip if you already have a healthy cluster)

```yaml
kubernetes_version: "1.35"                    # ≥ 1.33 (hard floor)
pod_network_cidr:   "10.244.0.0/16"           # Flannel default; change for Calico
flannel_version:    "v0.27.4"                 # pinned Flannel release
```

#### B2. CSI — TENANT-SCOPED (change per VAST tenant)

```yaml
vms_endpoint:  var203.selab.vastdata.com      # ← VMS hostname/IP
vms_tenant:    "ca-tenant"                    # ← tenant the CSI runs in; "" if not multi-tenant

storage_classes:                              # one StorageClass per key
  ca-sc1:
    vipPoolFQDN:  cavipool.selab-var203...    # ← must EXIST on the tenant
    storagePath:  /ca-storage                 # ← view path the CSI mounts under
    viewPolicy:   ca-tenant-nfs-policy        # ← must EXIST on the tenant
    deletionPolicy: Delete
  # add ca-sc2, ca-sc3, ... as needed
```

The credentials (`vault_vms_username` + `vault_vms_password` OR
`vault_vms_token`) go in `vault.yml`, not here.

#### B3. Zarf packages — how the two `.tar.zst` files reach the master

```yaml
zarf_packages:
  source: operator_download   # local | download | operator_download | upload
  dir:    "/home/{{ ansible_user }}/vast-zarf-packages"

  # For source=download OR source=operator_download:
  bundle_url: "https://files.vastdata.com/vast_dataengine_release_<N>_<pipeline>.tar.gz"

  # For source=operator_download — where on YOUR Mac to cache the download:
  operator_download_dir: "{{ lookup('env', 'HOME') }}/vast-zarf-packages"

  # For source=upload (instead of download):
  operator_init_path:       /path/on/your/mac/zarf-init-amd64-v0.60.0.tar.zst
  operator_dataengine_path: /path/on/your/mac/zarf-package-dataengine-amd64-1.0.0.tar.zst
```

Decision tree for `source`:

| Your situation | Use | Internet needed on |
| --- | --- | --- |
| Files already on the master | `local` | nobody |
| Master has internet egress; you have the SE link | `download` | master |
| Master is air-gapped; **you** can reach the SE link from this Mac | `operator_download` | operator (this Mac) |
| You already have the `.tar.zst` files on your Mac | `upload` | nobody |

#### B4. Storage class for Zarf seed-registry PVC

```yaml
storage:
  provisioner: byo            # byo | vast-csi | local-path | none
  class_name:  ca-sc2         # which StorageClass to mark default (byo / local-path)

# Which StorageClass `zarf init` will pass via --storage-class to its
# seed-registry PVC. Default: storage.class_name above. Override to any
# key from storage_classes: (the VAST CSI classes you defined in B2) or
# any other class that exists in the cluster. Empty = let zarf pick the
# cluster default.
zarf_init_storage_class: "{{ storage.class_name }}"
```

If you ran `make csi` first, use `provisioner: byo` and set `class_name`
to whichever class you want to be cluster default. For non-VAST quick
tests, `local-path` installs Rancher's local-path-provisioner.

To pin the seed registry to a specific VAST CSI class regardless of what
the cluster default is, set `zarf_init_storage_class: "ca-sc1"` (or
whichever key from `storage_classes:`).

#### B5. Users — K8s identities + kubeconfigs

```yaml
users:
  - name: k8s-admin                # K8s user identity (default; rename if you want)
    auth: cert                     # cert | token
    role: cluster-admin            # any ClusterRole that exists
    cert_days: 365                 # cert validity (cert auth only)
    cluster_name: vast-k8s         # appears in kubeconfig's clusters[].name
    # group: "system:masters"      # optional cert O= field
    # api_endpoint: https://<master>:6443    # optional override; default = master inventory IP

  # Example second user, token auth — uncomment to enable
  # - name: bob
  #   auth: token
  #   role: cluster-admin
  #   namespace: kube-system
```

Append entries for additional users. `make user` then produces one
`~/.kube/<name>.yaml` per entry (plus a `~/.kube/<name>-certs/` dir for
cert auth — see *What `make user` produces* above).

### C. `inventory/group_vars/all/vault.yml` — secrets

`make install` (or `make bootstrap`) already copied
`vault.yml.example` → `vault.yml` for you. Edit:

```yaml
vault_ansible_password:        "<sudo password on your nodes>"
vault_ansible_become_password: "<same as above; can differ if your sudo prompts>"
vault_vms_token:               ""                    # preferred; OR…
vault_vms_username:            "ca-tenant-admin"     # …user+pass
vault_vms_password:            "<VMS password>"
```

Then encrypt once:

```bash
make vault-encrypt        # one-time first encryption
# From now on:
make vault-edit           # opens decrypted in $EDITOR, re-encrypts on save
make vault-rekey          # rotate vault password
```

## Role catalog (19 roles)

| Role | Purpose | Used by playbook |
| --- | --- | --- |
| `common_prereqs` | apt-lock wait + cache refresh | k8s |
| `clustershell` | install clush, write `/etc/clustershell/groups.d/local.cfg` | k8s |
| `containerd` | install containerd from Docker repo, `SystemdCgroup=true` | k8s |
| `kubeadm_install` | install kubeadm/kubelet/kubectl (asserts ≥ 1.33) | k8s |
| `kubeadm_master` | `kubeadm init`, install Flannel CNI, generate join token | k8s |
| `kubeadm_worker` | `kubeadm join` | k8s |
| `firewall_k8s` | open K8s ports on firewalld / ufw | k8s |
| `nfs_client` | install `nfs-common` / `nfs-utils` | k8s, csi |
| `python_k8s_client` | pip-install `kubernetes` lib (required by every `kubernetes.core` task) | k8s, csi, zarf, users |
| `helm_install` | install Helm 3 binary | csi |
| `snapshot_crds` | apply external-snapshotter CRDs | csi |
| `vast_csi` | Helm install VAST CSI driver | csi |
| `inotify_limits` | sysctl tune for knative + KEDA | zarf |
| `zarf_install` | download zarf binary | zarf |
| `zarf_packages` | fetch (.tar.zst) packages — local/download/upload | zarf |
| `storage_class` | ensure default StorageClass — local-path/vast-csi/byo/none | zarf |
| `knative_crds` | pre-install knative-operator CRDs (bundled or upstream) | zarf |
| `dataengine_deploy` | `zarf init` + namespaces + `zarf package deploy` | zarf |
| `k8s_users` | RBAC + tokens or X.509 client certs + kubeconfig | users |

## Tags

Each playbook is tag-gated so partial runs are safe:

```bash
ansible-playbook collections/ansible_collections/vast/kubernetes/playbooks/site.yml --tags csi
ansible-playbook ... --tags k8s_prereqs   # only the apt + containerd prep
ansible-playbook ... --tags zarf_inotify  # only the sysctl tuning
ansible-playbook ... --tags k8s_master    # only the kubeadm init step
```

## Secrets

- **Storage:** `inventory/group_vars/all/vault.yml` (AES-256, ansible-vault).
- **Password:** `~/.config/vast-kubernetes/vault_pass`, referenced from
  `ansible.cfg`. Not in the repo.
- **Indirection:** roles never reference `vault_*` directly; `vars.yml`
  maps `vault_ansible_password` → `ansible_password`, etc.
- **Logging:** every task that consumes a secret carries `no_log: true`.
- **Vault lifecycle:**
  - `make vault-encrypt` — one-time first encryption (after `make bootstrap` lays down the plaintext template).
  - `make vault-edit` — opens decrypted in `$EDITOR`, re-encrypts on save. Fails clearly if not yet encrypted.
  - `make vault-rekey` — rotate the vault password.

## Verification

Three layers, in increasing cost and increasing signal:

```bash
# Layer 1 — offline (~10 sec; runs in CI, no SSH, no cluster needed)
make test
#   → ansible-playbook --syntax-check (5 playbooks)
#   → ansible-inventory --list (hosts.ini + localhost.ini)
#   → ansible-playbook --list-tasks (resolves roles + tags + vars)
#   → yamllint, ansible-lint (production profile), shellcheck, bash -n

# Layer 2 — read-only against the live cluster (~1 min)
ansible all -m ping                  # SSH + sudo proof
make check                           # ansible-playbook --check --diff against hosts.ini
#   Reports every task that would change, every file diff, every Helm release —
#   but mutates nothing. Aborts cleanly if a module can't simulate.

# Layer 3 — real deploy + idempotency
make site                            # the real thing
make site                            # second run MUST report changed=0
```

Latest verified live test (against the project's reference cluster — 2 nodes):

```
make check
PLAY RECAP
master   : ok=82   changed=9   failed=0   skipped=77   ✓
worker1  : ok=32   changed=4   failed=0   skipped=21   ✓
```

The 9 / 4 "would change" counts are all benign on first run:
apt cache refresh, Docker GPG key re-fetch (same bytes), cosmetic clustershell
comment update, intentional cleanup of pre-playbook `docker.list`, one-time
pip install of the `kubernetes` Python lib, and the kubeadm join-command file
re-emit. Second `make check` after a real run reports `changed=0`.

## PEP 668 / Debian 12+ / Ubuntu 24.04+

The `python_k8s_client` role installs the `kubernetes` Python lib via pip
even on PEP-668-locked systems. Defaults:

```yaml
python_k8s_client_pip_extra_args: "--break-system-packages --ignore-installed pyyaml"
```

Override to `""` and use a virtualenv if you prefer strict isolation.

## See also

- `docs/k8s-setup.md` — kubeadm bootstrap details (kubeadm_master, Flannel, join token)
- `docs/csi.md` — VAST CSI driver internals (Helm, snapshot CRDs, VMS auth)
- `docs/zarf.md` — DataEngine / Zarf pipeline (the 6-role chain)
- `docs/user-setup.md` — bash flow for K8s users (no-Ansible fallback)
