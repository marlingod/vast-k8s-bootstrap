# vast.kubernetes

Ansible collection that bootstraps a kubeadm Kubernetes cluster, installs the
VAST CSI driver, and deploys the VAST DataEngine via Zarf — plus bash scripts
for K8s user provisioning when an Ansible controller isn't available.

```
kubernetes/
├── Makefile                                # entry points: make k8s|csi|zarf|user|site|lint|check
├── ansible.cfg                             # collections_path, vault_password_file, inventory
├── inventory/
│   ├── hosts.ini                           # ONE inventory for everything
│   └── group_vars/all/
│       ├── vars.yml                        # non-secret defaults + vault_* indirection
│       └── vault.yml                       # ansible-vault encrypted secrets
├── requirements.yml                        # kubernetes.core, community.general, community.crypto, ansible.posix
├── requirements.txt                        # ansible, ansible-lint, kubernetes, ...
├── .ansible-lint .yamllint .pre-commit-config.yaml
├── collections/ansible_collections/vast/kubernetes/
│   ├── galaxy.yml
│   ├── playbooks/{site,k8s_cluster,csi,zarf,users}.yml   # thin orchestrators
│   └── roles/                              # 18 reusable roles (see Role catalog)
├── user-setup/                             # bash flow for environments without Ansible
└── docs/{k8s-setup,csi,zarf,user-setup}.md
```

## Quick start

```bash
# 1. Install deps
make install

# 2. Initialize the vault password file (one-time per machine)
mkdir -p ~/.config/vast-kubernetes
chmod 700 ~/.config/vast-kubernetes
echo 'changeme' > ~/.config/vast-kubernetes/vault_pass
chmod 600 ~/.config/vast-kubernetes/vault_pass

# 3. Encrypt the placeholder vault.yml (one-time per repo)
ansible-vault encrypt inventory/group_vars/all/vault.yml

# 4. Edit hosts + secrets
$EDITOR inventory/hosts.ini
make vault-edit                          # edits encrypted vault.yml

# 5. Run a phase
make k8s                                 # bootstrap kubeadm cluster
make csi                                 # install VAST CSI driver
make zarf                                # deploy VAST DataEngine
make user                                # provision K8s users
# or all of them in order:
make site
```

## Role catalog

| Role | Purpose | Used by playbook |
| --- | --- | --- |
| `common_prereqs` | apt-lock wait + cache refresh | k8s |
| `clustershell` | install clush, write `/etc/clustershell/groups.d/local.cfg` | k8s |
| `containerd` | install containerd from Docker repo, `SystemdCgroup=true` | k8s |
| `kubeadm_install` | install kubeadm/kubelet/kubectl from pkgs.k8s.io | k8s |
| `kubeadm_master` | `kubeadm init`, install Flannel CNI, generate join token | k8s |
| `kubeadm_worker` | `kubeadm join` | k8s |
| `firewall_k8s` | open K8s ports on firewalld / ufw | k8s |
| `nfs_client` | install `nfs-common` / `nfs-utils` | k8s, csi |
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
ansible-playbook ... --tags k8s_prereqs   # only the apt+containerd prep
ansible-playbook ... --tags zarf_inotify  # only the sysctl tuning
```

## Secrets

- **Storage**: `inventory/group_vars/all/vault.yml` (AES-256, ansible-vault).
- **Password**: `~/.config/vast-kubernetes/vault_pass`, referenced from
  `ansible.cfg`. Not in the repo.
- **Indirection**: roles never reference `vault_*` directly; `vars.yml`
  maps `vault_ansible_password` → `ansible_password`, etc.
- **Logging**: every task that consumes a secret carries `no_log: true`.

## Verification

```bash
ansible-playbook <site.yml> --syntax-check
make lint                                # ansible-lint + yamllint + shellcheck
make check                               # --check --diff dry run
make site                                # real run
make site                                # second run must report changed=0
```

## See also

- `docs/k8s-setup.md` — kubeadm bootstrap details
- `docs/csi.md` — CSI driver internals
- `docs/zarf.md` — DataEngine / Zarf details
- `docs/user-setup.md` — bash flow for K8s users
