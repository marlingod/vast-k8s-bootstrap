# k8s-setup Centralization & K8s 1.35 Upgrade — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `group_vars/all.yml` and `inventory.ini` the only places to change credentials, K8s version, and node IPs respectively. Delete the duplicated shell-scripts implementation. Upgrade Kubernetes from 1.29 to 1.35 (latest-1 minor as of 2026-05-28). Pin Flannel to a tagged release.

**Architecture:** Single Ansible toolchain. Hosts in `inventory.ini`; all other knobs in gitignored `group_vars/all.yml` with committed `all.yml.example` template. All playbooks reference these vars via Jinja — no literal IPs, passwords, versions, or user paths anywhere else.

**Tech Stack:** Ansible, Kubernetes 1.35 (kubeadm), containerd, Flannel v0.27.4, ClusterShell.

**Spec:** `docs/superpowers/specs/2026-05-28-k8s-setup-centralization-and-upgrade-design.md`

**Non-git workflow note:** This project is not under git. There are no `git commit` steps. Each task that modifies an existing file is preceded by a `cp file file.bak` backup. The final task removes backups after live verification.

---

### Task 0: Pre-flight safety

**Files:**
- Create (optional): `.git/` via `git init`

- [ ] **Step 1: Ask the user to confirm `certs/` can be deleted**

The directory `k8s-setup/certs/` contains `ca.crt`, `client.crt`, `client.key.b64` and is not referenced by any playbook, script, or README. Ask the user:

> "I'm about to delete `k8s-setup/certs/` (Task 11). It contains `ca.crt`, `client.crt`, `client.key.b64` and isn't referenced by any deployment file. Confirm deletion, or tell me what to do with it instead."

If the user says keep, skip Task 11 entirely and note that decision here.

- [ ] **Step 2: Offer `git init` for rollback safety**

Run: `git rev-parse --is-inside-work-tree 2>&1`
Expected: `fatal: not a git repository`

Ask the user:

> "This project is not under git. Want me to `git init` and commit the current state as a baseline? It gives you a clean rollback if anything goes wrong. (You're not committing the password — `group_vars/all.yml` is gitignored from Task 1.)"

If yes:
```bash
cd /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup
git init
git add -A
git commit -m "baseline: pre-centralization state"
```

If no, proceed — backups via `.bak` files instead.

- [ ] **Step 3: Confirm target K8s minor is still 1.35**

Run: `curl -s https://dl.k8s.io/release/stable.txt`
Expected output begins with `v1.36.` (so latest-1 minor = 1.35). If it instead begins with `v1.37.` or later, stop and tell the user — the target minor needs to be updated to one below whatever upstream reports.

---

### Task 1: Create `.gitignore` (FIRST — before any secrets file exists)

**Files:**
- Create: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/.gitignore`

- [ ] **Step 1: Write the file**

Path: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/.gitignore`

Contents:
```text
# Ansible secrets — never commit
ansible/group_vars/all.yml

# Fetched join command (contains a token)
ansible/k8s-join-command.sh
k8s-join-command.sh

# Ansible retry files
*.retry

# Editor / OS noise
.DS_Store
*.swp
```

- [ ] **Step 2: Verify**

Run: `cat /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/.gitignore | head -3`
Expected first non-blank line: `# Ansible secrets — never commit`

---

### Task 2: Create `group_vars/all.yml.example` (committed template)

**Files:**
- Create: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml.example`

- [ ] **Step 1: Make the directory**

Run: `mkdir -p /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars`
Expected: no output (directory created or already exists).

- [ ] **Step 2: Write the template**

Path: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml.example`

Contents:
```yaml
---
# Copy this file to all.yml and fill in real values.
# all.yml is gitignored — never commit secrets.
#
# This is the ONE place to change credentials, K8s version,
# CNI version, and the SSH user. Node IPs live in inventory.ini.

# --- SSH / sudo credentials ---
ansible_user: vastdata
ansible_password: CHANGE_ME
ansible_become_password: CHANGE_ME

# --- Kubernetes ---
# apt/yum repo path resolves to: v{{ kubernetes_version }}
# Patch version is selected automatically by the package manager.
kubernetes_version: "1.35"

# Flannel default pod network. Must match what Flannel expects.
pod_network_cidr: "10.244.0.0/16"

# Pinned Flannel release (no more `releases/latest/`).
flannel_version: "v0.27.4"
```

- [ ] **Step 3: Verify**

Run: `head -3 /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml.example`
Expected:
```
---
# Copy this file to all.yml and fill in real values.
# all.yml is gitignored — never commit secrets.
```

---

### Task 3: Create real `group_vars/all.yml` from template

**Files:**
- Create: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml`

- [ ] **Step 1: Copy template to real file**

Run:
```bash
cp /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml.example \
   /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml
```
Expected: no output.

- [ ] **Step 2: Fill in real passwords**

Edit `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml`:

Replace:
```yaml
ansible_password: CHANGE_ME
ansible_become_password: CHANGE_ME
```

With:
```yaml
ansible_password: vastdata
ansible_become_password: vastdata
```

- [ ] **Step 3: Verify file permissions and contents**

Run: `chmod 600 /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml && stat -f '%Sp' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml`
Expected: `-rw-------`

Run: `grep -c 'CHANGE_ME' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/group_vars/all.yml`
Expected: `0`

---

### Task 4: Slim down `inventory.ini` — IPs only, no credentials

**Files:**
- Modify: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/inventory.ini`

- [ ] **Step 1: Back up**

Run: `cp /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/inventory.ini{,.bak}`
Expected: no output.

- [ ] **Step 2: Replace file contents**

Path: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/inventory.ini`

Replace the entire file with:
```ini
# Inventory: hosts and IPs ONLY.
# Credentials, K8s version, and other knobs live in group_vars/all.yml.

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

- [ ] **Step 3: Verify no passwords remain**

Run: `grep -E 'ansible_password|ansible_become_password|vastdata' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/inventory.ini`
Expected: no output (exit code 1).

Run: `grep -c '10.143.2' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/inventory.ini`
Expected: `2` (one per host, no duplication).

---

### Task 5: Clean `ansible.cfg` — drop `remote_user`

**Files:**
- Modify: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/ansible.cfg`

- [ ] **Step 1: Back up**

Run: `cp /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/ansible.cfg{,.bak}`
Expected: no output.

- [ ] **Step 2: Replace file contents**

Path: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/ansible.cfg`

Replace with:
```ini
[defaults]
inventory = inventory.ini
host_key_checking = False
deprecation_warnings = False
command_warnings = False
timeout = 30

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
pipelining = True
```

(The `remote_user = vastdata` line is removed — `ansible_user` from `group_vars/all.yml` supplies it now.)

- [ ] **Step 3: Verify**

Run: `grep -E 'remote_user|vastdata' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/ansible.cfg`
Expected: no output (exit code 1).

---

### Task 6: Template `01-install-clush.yml` — no hardcoded IPs or user

**Files:**
- Modify: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/01-install-clush.yml`

- [ ] **Step 1: Back up**

Run: `cp /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/01-install-clush.yml{,.bak}`

- [ ] **Step 2: Edit the clush groups block**

In `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/01-install-clush.yml`, find the `Configure ClusterShell groups` task (currently around line 44). Replace the `content:` block of that task from:

```yaml
        content: |
          # Kubernetes cluster groups
          all: master,worker1
          masters: master
          workers: worker1
          k8s: @masters,@workers

          # Node aliases
          master: 10.143.2.65
          worker1: 10.143.2.69
```

To:

```yaml
        content: |
          # Kubernetes cluster groups
          all: master,worker1
          masters: master
          workers: worker1
          k8s: @masters,@workers

          # Node aliases (IPs sourced from Ansible inventory)
          master: {{ hostvars['master'].ansible_host }}
          worker1: {{ hostvars['worker1'].ansible_host }}
```

- [ ] **Step 3: Edit the clush SSH user**

In the same file, find the `Configure ClusterShell defaults` task (currently around line 59). Replace:

```yaml
          [SSH]
          ssh_user: vastdata
```

With:

```yaml
          [SSH]
          ssh_user: {{ ansible_user }}
```

- [ ] **Step 4: Verify no hardcoded values remain in this file**

Run: `grep -E '10\.143\.2|ssh_user: vastdata' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/01-install-clush.yml`
Expected: no output (exit code 1).

---

### Task 7: Update `02-k8s-prerequisites.yml` — drop inline vars, bump version

**Files:**
- Modify: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/02-k8s-prerequisites.yml`

- [ ] **Step 1: Back up**

Run: `cp /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/02-k8s-prerequisites.yml{,.bak}`

- [ ] **Step 2: Remove the inline `vars:` block**

In `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/02-k8s-prerequisites.yml`, find lines 10-13:

```yaml
  vars:
    kubernetes_version: "1.29"
    containerd_version: "1.7"

  tasks:
```

Replace with:

```yaml
  tasks:
```

(`kubernetes_version` now comes from `group_vars/all.yml`. `containerd_version` was set but never used anywhere in the playbook — confirmed by grep — so it is removed entirely.)

- [ ] **Step 3: Verify no inline `kubernetes_version: "1.29"` remains**

Run: `grep -E 'kubernetes_version:.*1\.29|containerd_version' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/02-k8s-prerequisites.yml`
Expected: no output (exit code 1).

Run: `grep -c '{{ kubernetes_version }}' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/02-k8s-prerequisites.yml`
Expected: `4` (two repo URLs for Debian, two for RHEL — both the GPG key URL and the repo URL on each OS).

---

### Task 8: Update `03-k8s-master-init.yml` — group_vars, pin Flannel, drop --ignore-preflight, ansible_user paths

**Files:**
- Modify: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/03-k8s-master-init.yml`

- [ ] **Step 1: Back up**

Run: `cp /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/03-k8s-master-init.yml{,.bak}`

- [ ] **Step 2: Replace the inline `vars:` block**

In `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/03-k8s-master-init.yml`, find lines 10-13:

```yaml
  vars:
    pod_network_cidr: "10.244.0.0/16"
    kubernetes_api_advertise_address: "{{ ansible_default_ipv4.address }}"

  tasks:
```

Replace with:

```yaml
  vars:
    # pod_network_cidr comes from group_vars/all.yml.
    # API server advertise address is taken from the inventory (deterministic)
    # rather than ansible_default_ipv4.address (which can pick the wrong NIC).
    kubernetes_api_advertise_address: "{{ hostvars[inventory_hostname].ansible_host }}"

  tasks:
```

- [ ] **Step 3: Drop `--ignore-preflight-errors=all` from kubeadm init**

In the same file, find the `Initialize Kubernetes master` task (currently around lines 20-27). Replace:

```yaml
    - name: Initialize Kubernetes master
      command: >
        kubeadm init
        --apiserver-advertise-address={{ kubernetes_api_advertise_address }}
        --pod-network-cidr={{ pod_network_cidr }}
        --ignore-preflight-errors=all
      register: kubeadm_init
      when: not k8s_init_check.stat.exists
```

With:

```yaml
    - name: Initialize Kubernetes master
      command: >
        kubeadm init
        --apiserver-advertise-address={{ kubernetes_api_advertise_address }}
        --pod-network-cidr={{ pod_network_cidr }}
      register: kubeadm_init
      when: not k8s_init_check.stat.exists
```

- [ ] **Step 4: Replace `/home/vastdata` paths and vastdata ownership**

In the same file, find both `.kube` directory tasks and the kube config copy task (currently around lines 34-49). Replace each occurrence:

| Old | New |
| --- | --- |
| `/home/vastdata/.kube` | `/home/{{ ansible_user }}/.kube` |
| `/home/vastdata/.kube/config` | `/home/{{ ansible_user }}/.kube/config` |
| `owner: vastdata` | `owner: "{{ ansible_user }}"` |
| `group: vastdata` | `group: "{{ ansible_user }}"` |

(Use `replace_all` for `/home/vastdata` and `vastdata` in owner/group lines — but be careful: `become_user: vastdata` for kubectl steps should also become `become_user: "{{ ansible_user }}"`.)

After the edits, those tasks should look like:

```yaml
    - name: Create .kube directory for {{ ansible_user }}
      file:
        path: "/home/{{ ansible_user }}/.kube"
        state: directory
        owner: "{{ ansible_user }}"
        group: "{{ ansible_user }}"
        mode: '0755'

    - name: Copy admin.conf to {{ ansible_user }}
      copy:
        src: /etc/kubernetes/admin.conf
        dest: "/home/{{ ansible_user }}/.kube/config"
        remote_src: yes
        owner: "{{ ansible_user }}"
        group: "{{ ansible_user }}"
        mode: '0600'
```

- [ ] **Step 5: Replace all `become_user: vastdata`**

Find every `become_user: vastdata` line in the file (there are four: Flannel install, Flannel wait, get cluster status, and the same pattern in 04-k8s-worker-join.yml is handled in Task 9). Replace each with `become_user: "{{ ansible_user }}"`.

- [ ] **Step 6: Pin Flannel to a tagged release**

Find the `Install Flannel CNI` task (currently around line 64). Replace:

```yaml
      command: kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

With:

```yaml
      command: kubectl apply -f https://github.com/flannel-io/flannel/releases/download/{{ flannel_version }}/kube-flannel.yml
```

- [ ] **Step 7: Replace remaining `/home/vastdata/` paths (join command save and fetch)**

Find the `Save join command to file` task (around line 84). Replace `dest: /home/vastdata/k8s-join-command.sh` with `dest: "/home/{{ ansible_user }}/k8s-join-command.sh"`. Replace `owner: vastdata` / `group: vastdata` with `owner: "{{ ansible_user }}"` / `group: "{{ ansible_user }}"`.

Find the `Fetch join command to local machine` task (around line 96). Replace `src: /home/vastdata/k8s-join-command.sh` with `src: "/home/{{ ansible_user }}/k8s-join-command.sh"`.

- [ ] **Step 8: Verify no hardcoded `vastdata` or 1.29 remains**

Run: `grep -nE '/home/vastdata|owner: vastdata|group: vastdata|become_user: vastdata|releases/latest|ignore-preflight-errors' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/03-k8s-master-init.yml`
Expected: no output (exit code 1).

---

### Task 9: Update `04-k8s-worker-join.yml` — ansible_user paths

**Files:**
- Modify: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/04-k8s-worker-join.yml`

- [ ] **Step 1: Back up**

Run: `cp /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/04-k8s-worker-join.yml{,.bak}`

- [ ] **Step 2: Replace `become_user: vastdata`**

In `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/04-k8s-worker-join.yml`, find every `become_user: vastdata` (currently three: wait for ready, get final status, get all pods — lines 51, 59, 69). Replace each with `become_user: "{{ ansible_user }}"`.

- [ ] **Step 3: Verify**

Run: `grep -E 'vastdata' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible/04-k8s-worker-join.yml`
Expected: no output (exit code 1).

---

### Task 10: Delete `scripts/` directory

**Files:**
- Delete: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/scripts/`

- [ ] **Step 1: Confirm contents first**

Run: `ls /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/scripts/`
Expected output (exactly these 5 files):
```
01-install-clush.sh
02-k8s-setup-all-nodes.sh
03-k8s-init-master.sh
04-k8s-join-worker.sh
deploy-k8s-cluster.sh
```

If any other file is present, stop and ask the user.

- [ ] **Step 2: Delete**

Run: `rm -rf /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/scripts`
Expected: no output.

- [ ] **Step 3: Verify**

Run: `ls /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/scripts 2>&1`
Expected: `ls: ...: No such file or directory`

---

### Task 11: Delete `certs/` directory (only if confirmed in Task 0 Step 1)

**Files:**
- Delete: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/certs/`

- [ ] **Step 1: Skip-or-proceed gate**

If the user declined deletion in Task 0 Step 1, skip this entire task and continue to Task 12.

- [ ] **Step 2: Delete**

Run: `rm -rf /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/certs`
Expected: no output.

- [ ] **Step 3: Verify**

Run: `ls /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/certs 2>&1`
Expected: `ls: ...: No such file or directory`

---

### Task 12: Rewrite the README

**Files:**
- Modify: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/README.md`

- [ ] **Step 1: Back up**

Run: `cp /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/README.md{,.bak}`

- [ ] **Step 2: Replace the entire file**

Path: `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/README.md`

Replace with:
```markdown
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
```

- [ ] **Step 3: Verify no leftover hardcoded values**

Run: `grep -nE '10\.143\.2|vastdata:vastdata|"1\.29"' /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/README.md`
Expected: no output (exit code 1).

---

### Task 13: Static verification

- [ ] **Step 1: Syntax check the master playbook**

Run:
```bash
cd /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible && \
  ansible-playbook --syntax-check -i inventory.ini site.yml
```
Expected output ends with: `playbook: site.yml` and exit code `0`.

If `ansible-playbook` is not installed, stop and tell the user: `pip install ansible`.

- [ ] **Step 2: Lint (if `ansible-lint` is installed)**

Run:
```bash
cd /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible && \
  command -v ansible-lint && ansible-lint *.yml || echo "ansible-lint not installed, skipping"
```
Expected: either clean lint or "not installed, skipping". Any lint *errors* (not warnings) must be fixed before continuing.

- [ ] **Step 3: Hardcoded-value scan — passwords and old version**

Run:
```bash
cd /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup && \
  grep -RnE 'vastdata:vastdata|"1\.29"' ansible/ README.md
```
Expected: no output (exit code 1). If anything matches, fix the file it points to before continuing.

- [ ] **Step 4: Hardcoded-value scan — IPs live in exactly one file**

Run:
```bash
cd /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup && \
  grep -RnE '10\.143\.2\.(65|69)' ansible/ README.md
```
Expected: every line of output starts with `ansible/inventory.ini:`. If any other file matches, that file still has a hardcoded IP — fix it before continuing.

- [ ] **Step 5: Confirm the K8s version reference resolves to 1.35**

Run:
```bash
cd /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup && \
  grep -nE 'kubernetes_version' ansible/group_vars/all.yml
```
Expected: `kubernetes_version: "1.35"`

---

### Task 14: Live deploy (operator-driven)

This task is for the operator (you / the user) to run, not the agent. The agent stops after Task 13 and hands off.

- [ ] **Step 1: Reset existing clusters on both nodes**

For each of `10.143.2.65` and `10.143.2.69`:
```bash
ssh vastdata@<node-ip>
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/kubelet/* ~/.kube
exit
```

- [ ] **Step 2: Run the playbook**

```bash
cd /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/ansible
ansible-playbook -i inventory.ini site.yml
```
Expected: the play recap at the end shows `failed=0` for both `master` and `worker1`.

If kubeadm preflight fails (because we removed `--ignore-preflight-errors=all`), read the error. If it's a check you legitimately need to ignore (e.g., low memory in a test environment), narrow the flag in `03-k8s-master-init.yml` to that single check (e.g., `--ignore-preflight-errors=Mem`) and re-run — do not restore `=all`.

- [ ] **Step 3: Verify cluster is up and on 1.35**

```bash
ssh vastdata@10.143.2.65
kubectl get nodes -o wide
kubectl get pods -A
```

Expected:
- Both nodes show `Ready`.
- The `VERSION` column shows `v1.35.x` for both.
- `kube-flannel` pods show `Running`.

- [ ] **Step 4: Remove `.bak` backups (only after Step 3 succeeds)**

```bash
cd /Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup
find . -name '*.bak' -type f -delete
```

If the live deploy failed, leave the `.bak` files in place — they are your rollback path: `for f in $(find . -name '*.bak'); do mv "$f" "${f%.bak}"; done`.

---

## Self-Review

**Spec coverage check:**
- "One place to change server addresses" → `inventory.ini` (Task 4, verified Task 13 Step 4). ✓
- "One place to change password" → `group_vars/all.yml` (Tasks 2-5, verified Task 13 Step 3). ✓
- "Install latest-1 K8s" → `kubernetes_version: "1.35"` (Task 2, verified Task 0 Step 3 and Task 13 Step 5). ✓
- Eliminate duplicated implementation → `scripts/` deleted (Task 10). ✓
- Drop `--ignore-preflight-errors=all` → Task 8 Step 3. ✓
- Pin Flannel → Task 8 Step 6. ✓
- `/home/vastdata` → `/home/{{ ansible_user }}` → Task 8 Steps 4-7, Task 9 Step 2. ✓
- Master IP from inventory (not `ansible_default_ipv4`) → Task 8 Step 2. ✓
- `.gitignore` and example template → Tasks 1, 2. ✓
- README rewrite → Task 12. ✓
- Verification commands match spec § Verification → Task 13 Steps 1-5. ✓
- `certs/` decision → Task 0 Step 1 + Task 11. ✓

**Placeholder scan:** No "TBD", "TODO", or "fill in details" present. Every code/config block is complete. Every command shows expected output. ✓

**Type / name consistency:**
- `ansible_user`, `ansible_password`, `ansible_become_password`, `kubernetes_version`, `pod_network_cidr`, `flannel_version` — used consistently in Tasks 2-9.
- `{{ hostvars['master'].ansible_host }}` syntax used identically in Task 6 (clush groups) and Task 8 (kubeadm advertise). ✓
- File paths to `/Users/yemalin.godonou/Documents/vast/kubernetes/k8s-setup/...` are absolute and identical everywhere. ✓
