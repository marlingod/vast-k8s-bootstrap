# K8s user provisioning

Two paths to the same outcome:

- **Ansible** — `playbooks/users.yml` driven by the `users:` list in
  `vars.yml` (or passed via `-e`). Uses `kubernetes.core.k8s` +
  `community.crypto.openssl_*` for the CSR flow.
- **Bash** — `user-setup/*.sh` scripts for environments without an Ansible
  controller. Maps 1:1 to the Ansible role behavior.

## Ansible flow

Add users to `inventory/group_vars/all/vars.yml`:

```yaml
users:
  - name: alice
    auth: cert
    role: cluster-admin
    group: ""
    cert_days: 365
    cluster_name: vastde-cluster
    api_endpoint: https://10.143.2.26:6443
  - name: bob
    auth: token
    role: cluster-admin
    namespace: kube-system
```

Then:

```bash
make user
# → kubeconfigs/{alice,bob}.kubeconfig on the local control machine
```

## Bash flow

See `user-setup/README.md`. Three scripts, all standalone:

| Script | Auth |
| --- | --- |
| `create-user.sh` | ServiceAccount + bearer token |
| `create-user-cert.sh` | X.509 cert (local CSR submission) |
| `create-user-cert-remote.sh` | X.509 cert via SSH (private key never leaves laptop). `--format kubeconfig\|pem\|both` |

## Changes from the legacy `user-setup/`

| Before | After |
| --- | --- |
| `cluaster-admin.yaml` (typo) | `rbac/cluster-admin.yaml` |
| `create-user-cert-remote.sh` + `dump-user-certs-remote.sh` (90% duplicated) | merged into one with `--format` |
| Hardcoded `sshpass -p <literal>` | requires key-based SSH; password via `SSHPASS` env only |
| `0644` PEM files | `0600` everywhere |
| `EDIT THESE` block at top of every script | proper CLI flags with `--user`, `--host`, etc. |
| Duplicate copy at `k8s2/k8s-setup/user-setup/` | deleted |

## Security

- Private key generated locally; never crosses SSH.
- Vault password file in `~/.config/vast-kubernetes/vault_pass`, not in repo.
- `no_log: true` on every Ansible task that touches `vault_*`.
- `umask 077` + `chmod 600` on every output file.
