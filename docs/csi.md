# VAST CSI driver install

`playbooks/csi.yml` runs three roles on `csi_controller` (typically the
master) and `nfs_client` on every `nfs_targets` host (workers + sometimes
master).

| Role | What it does |
| --- | --- |
| `nfs_client` | `nfs-common` (Debian) / `nfs-utils` (RHEL). Missing it is the #1 cause of "PVC mount timeout" failures. |
| `helm_install` | Helm 3 binary install via `get_url` + `unarchive` (no curl-pipe-to-bash). |
| `snapshot_crds` | External-snapshotter CRDs from a pinned version. Set `install_snapshot_crds: false` to skip if you already have them. |
| `vast_csi` | Renders the per-cluster `values.yaml.j2`, adds the Helm repo, runs `kubernetes.core.helm` install/upgrade. |

## Configuration

Everything is in `inventory/group_vars/all/vars.yml` under the CSI section.

| Key | Default | Notes |
| --- | --- | --- |
| `csi_namespace` | `vastcsi` | |
| `csi_release_name` | `csi-driver` | Helm release name |
| `vast_csi_chart_version` | `""` (latest) | Pin like `"2.6.5"` for prod |
| `csi_driver_name` | `vastdriver.vastdata.com` | becomes `csiDriverName` in values |
| `vms_endpoint` | `var203.selab.vastdata.com` | |
| `vms_tenant` | `ca-tenant` | optional |
| `verify_ssl` | `false` | |
| `storage_classes` | dict | one StorageClass per key |

## Secrets

Two auth modes, sourced from `vault.yml`:

1. **Token** — set `vault_vms_token`. Preferred.
2. **User/pass** — set `vault_vms_username` + `vault_vms_password`.

The `vast_csi` role builds the Secret using `kubernetes.core.k8s` with
`no_log: true` on every task that touches the credentials.

## Verification

```bash
make csi
kubectl -n vastcsi get pods         # controller + node-driver pods Running
kubectl get sc                      # one entry per storage_classes key
```

End-to-end smoke test (formerly `05-verify.yml`): not yet ported to a role.
Use the legacy script from git history if needed, or `kubectl apply` a small
PVC + StatefulSet manually.
