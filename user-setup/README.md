# user-setup — bash flow for provisioning K8s users

For environments without an Ansible controller. The equivalent Ansible role
lives at `collections/ansible_collections/vast/kubernetes/roles/k8s_users/`
and is exposed via `playbooks/users.yml` / `make user`.

## Scripts

| Script | Auth method | Output |
| --- | --- | --- |
| `create-user.sh` | ServiceAccount + bearer token | kubeconfig |
| `create-user-cert.sh` | X.509 client cert (local CSR) | kubeconfig |
| `create-user-cert-remote.sh` | X.509 client cert (SSH-driven CSR on the master) | kubeconfig, PEM files, or both (`--format`) |

All scripts:

- `set -euo pipefail`, `umask 077`.
- Refuse to leak SSH/sudo passwords on the command line. Use `SSHPASS=...` /
  `SUDOPASS=...` env vars only when key-based SSH and NOPASSWD sudo aren't
  available.
- Write keys and kubeconfigs with mode `0600`.

## Example

```bash
# Cluster-admin via cert, remote master at 10.0.0.5
./create-user-cert-remote.sh \
  --user alice \
  --host 10.0.0.5 \
  --ssh-user vastdata \
  --role cluster-admin \
  --format both
```

## RBAC templates

`rbac/cluster-admin.yaml`, `rbac/sa.yaml`, `rbac/token.yaml` — sample
manifests for hand-rolling a ServiceAccount + ClusterRoleBinding.

## Changelog

- `cluaster-admin.yaml` renamed to `cluster-admin.yaml` (typo fix).
- `create-user-cert-remote.sh` and `dump-user-certs-remote.sh` merged into
  a single script with `--format`.
- All hardcoded SSH passwords removed; use `SSHPASS` env var.
