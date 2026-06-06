# k8s-setup: Centralize Configuration & Upgrade to Kubernetes 1.35

**Date:** 2026-05-28
**Status:** Approved
**Scope:** `k8s-setup/` deployment automation

## Goals

1. **One place to change** server addresses and SSH/sudo password.
2. **Upgrade Kubernetes** from 1.29 to latest-1 minor (1.35).
3. **Eliminate duplicated implementations** (shell scripts and Ansible doing the same thing).
4. **Bundle in low-risk quality and security fixes** to files we are already touching.

## Non-Goals

- SSH key-based auth (deferred; password auth retained, just centralized).
- Ansible Vault or other secret encryption.
- In-place upgrade of an existing running cluster (this design assumes fresh install; an existing 1.29 cluster will be `kubeadm reset -f` first).
- Additional CNI choices, multi-master HA, Helm/ingress/metrics-server install.

## Decisions

| Decision | Choice |
| --- | --- |
| Tooling | Ansible only. Delete `scripts/`. |
| Secrets handling | Plaintext in `group_vars/all.yml`, gitignored. Committed `all.yml.example` template. |
| K8s version | `1.35` (latest-1 minor as of 2026-05-28; upstream stable is `v1.36.1`). Patch resolves to `1.35.5` via apt/yum. |
| Flannel version | Pinned to `v0.27.4` (no more `releases/latest/`). |
| Preflight errors | Drop `--ignore-preflight-errors=all`; let `kubeadm init` fail loudly. |
| Existing cluster | Operator runs `kubeadm reset -f` on both nodes before re-deploy. |

## Target File Layout

```text
k8s-setup/
├── README.md                              # rewritten: Ansible-only flow
├── .gitignore                             # NEW: ignores secrets and fetched artifacts
├── docs/superpowers/specs/                # this document
└── ansible/
    ├── ansible.cfg                        # cleaned: no remote_user, no passwords
    ├── inventory.ini                      # hosts only; references vars
    ├── group_vars/
    │   ├── all.yml                        # GITIGNORED. Single source of truth.
    │   └── all.yml.example                # committed template
    ├── site.yml                           # unchanged
    ├── 01-install-clush.yml               # templated IPs and SSH user
    ├── 02-k8s-prerequisites.yml           # uses kubernetes_version
    ├── 03-k8s-master-init.yml             # uses pod_network_cidr, flannel_version, ansible_user
    └── 04-k8s-worker-join.yml             # uses ansible_user
```

Deleted: `scripts/` (5 files). `certs/` to be confirmed unrelated; if it is unused by the deployment, it is also deleted.

## Single Source of Truth: Two Files, One Per Kind of Config

INI inventory files do not support Jinja substitution, so we cannot put `ansible_host={{ master_ip }}` in `inventory.ini`. Instead we use the Ansible-idiomatic split: each kind of config lives in exactly one file.

| Kind of config | Lives in | Why |
| --- | --- | --- |
| Host IP addresses | `inventory.ini` | Inventory is the canonical place for hostnames/IPs in Ansible. |
| Credentials, K8s version, CIDR, Flannel version, SSH user | `group_vars/all.yml` | Single file for all "knobs". Gitignored because it holds the password. |

**"One place to change" is satisfied** because the master IP appears in exactly one file (`inventory.ini`), the password appears in exactly one file (`group_vars/all.yml`), the K8s version appears in exactly one file (`group_vars/all.yml`), etc. No value appears in two files.

The committed `all.yml.example`:

```yaml
---
# Copy this file to all.yml and fill in real values.
# all.yml is gitignored; never commit secrets.

# --- Credentials ---
ansible_user: vastdata
ansible_password: CHANGE_ME
ansible_become_password: CHANGE_ME

# --- Kubernetes ---
kubernetes_version: "1.35"            # apt/yum repo path: v{{ kubernetes_version }}
pod_network_cidr: "10.244.0.0/16"     # Flannel default
flannel_version: "v0.27.4"            # pinned; no longer `latest`
```

`inventory.ini` (no passwords, no per-host duplication):

```ini
[masters]
master ansible_host=10.143.2.65

[workers]
worker1 ansible_host=10.143.2.69

[k8s:children]
masters
workers

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
ansible_become=yes
```

`ansible.cfg` retains operational settings (timeout, ssh args, become method) but no longer carries `remote_user` or any password — those come from `group_vars/all.yml`.

## Playbook Changes (Templating)

All occurrences of hardcoded values become Jinja references to vars from `group_vars/all.yml`:

| Currently hardcoded | Replaced by |
| --- | --- |
| `10.143.2.65`, `10.143.2.69` in playbooks/configs | `{{ hostvars['master'].ansible_host }}` / `{{ hostvars['worker1'].ansible_host }}` (only place the literal IPs live is `inventory.ini`) |
| `vastdata` password | `{{ ansible_password }}` / `{{ ansible_become_password }}` |
| `/home/vastdata/…` | `/home/{{ ansible_user }}/…` |
| `vastdata:vastdata` (file ownership) | `{{ ansible_user }}:{{ ansible_user }}` |
| `ssh_user: vastdata` in clush conf | `ssh_user: {{ ansible_user }}` |
| `1.29` k8s version | `{{ kubernetes_version }}` |
| Flannel `releases/latest/...` URL | `releases/download/{{ flannel_version }}/kube-flannel.yml` |
| `--ignore-preflight-errors=all` | flag removed |
| `--apiserver-advertise-address` from `ansible_default_ipv4.address` | `{{ hostvars[inventory_hostname].ansible_host }}` (deterministic per inventory) |

`02-k8s-prerequisites.yml` removes its inline `vars:` block; the version lives in `group_vars/all.yml` only.

`03-k8s-master-init.yml` removes its inline `vars:` block for `pod_network_cidr` and `kubernetes_api_advertise_address`; both come from `group_vars/all.yml` / inventory.

## README Rewrite

The README becomes a single short flow:

1. Install Ansible: `pip install ansible`.
2. `cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml` and edit.
3. `cd ansible && ansible-playbook -i inventory.ini site.yml`.

The IP/credential table and the "Option 1 / Option 2" split are removed. The README points to `group_vars/all.yml` as the configuration location.

## `.gitignore` (new file at repo root)

```text
ansible/group_vars/all.yml
ansible/k8s-join-command.sh
k8s-join-command.sh
*.retry
```

## Verification

Per superpowers verification-before-completion rules, the following must pass and the output be observed (not assumed) before claiming completion:

1. **Syntax check:** `ansible-playbook --syntax-check -i inventory.ini site.yml` returns 0.
2. **Lint (if installed):** `ansible-lint` reports no errors on changed playbooks.
3. **Hardcoded-value scan:** `grep -RnE 'vastdata:vastdata|"1\.29"' ansible/ README.md` returns zero matches. Additionally, the IPs `10.143.2.65` and `10.143.2.69` appear in exactly one place: `ansible/inventory.ini`. Verified with `grep -RnE '10\.143\.2\.(65|69)' ansible/ README.md` — output lists only `inventory.ini`.
4. **Live deploy** against the two nodes after `kubeadm reset -f` on each:
   - `kubectl get nodes -o wide` shows both nodes `Ready`.
   - Reported version on both nodes is `v1.35.x`.
   - `kubectl get pods -A` shows `kube-flannel` pods `Running`.

Each verification step's command output is captured in the implementation summary; success is asserted only after observing the output, never inferred.

## Risks & Mitigations

| Risk | Mitigation |
| --- | --- |
| Existing 1.29 cluster blocks fresh init | Operator reset (`kubeadm reset -f`) is called out in README and in the implementation plan's pre-flight checklist. |
| Dropping `--ignore-preflight-errors=all` exposes a real preflight failure on the target nodes | If a specific check is known to legitimately fail in this environment, narrow the flag to that single check (e.g., `=Mem`) rather than `=all`. Will be revisited during the live run. |
| Flannel `v0.27.4` incompatible with K8s 1.35 | v0.27.4 supports K8s 1.30+ per upstream notes. If unavailable, fall back to the latest tag that does. |
| `group_vars/all.yml` accidentally committed before `.gitignore` lands | Implementation plan creates `.gitignore` and example template **before** creating `all.yml`. |

## Out of Scope (for follow-up)

- Migrate to SSH key auth and drop `ansible_password` entirely.
- Wrap `all.yml` in Ansible Vault for safe commit.
- Add a `Makefile` or `justfile` for the common commands.
- Add support for >1 worker via inventory-driven loops (current setup with one explicit `worker1` entry is fine but won't scale automatically).
