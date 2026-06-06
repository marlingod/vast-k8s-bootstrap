# VAST DataEngine deploy via Zarf

`playbooks/zarf.yml` is the air-gapped-capable deploy path. It depends on a
running K8s cluster (`make k8s`) and, optionally, the VAST CSI driver
(`make csi`) for a real default StorageClass.

## Roles

1. **`inotify_limits`** — runs on every K8s node. Tunes
   `fs.inotify.max_user_instances` and `max_user_watches` via
   `ansible.posix.sysctl` to a drop-in file. Knative + KEDA + the VAST
   operator + 5 telemetry collectors blow past kernel defaults; pods
   CrashLoopBackOff at startup without this.
2. **`zarf_install`** — downloads the zarf binary (pinned by `zarf_version`)
   and installs it to `zarf_install_dir`. Skips if `zarf_detect_existing` is
   true and a zarf binary is already on PATH.
3. **`zarf_packages`** — fetches the two VAST `.tar.zst` files (init + DataEngine).
   Three source modes:
    - `local` — files already on the master under `zarf_packages.dir`. Fail
      fast if missing.
    - `download` — the master fetches `bundle_url` over the internet.
    - `upload` — scp from the operator's local machine. Two flavors detected
      automatically: `files` (two `.tar.zst`) or `bundle` (one outer
      `.tar.gz` that gets extracted on the master).
4. **`storage_class`** — ensures a default StorageClass. `zarf init` hangs
   ~15 min waiting on a PVC if there's no default. Four provisioner branches
   (`storage.provisioner`): `local-path`, `vast-csi`, `byo`, `none`.
5. **`knative_crds`** — pre-installs the two `knative*.operator.knative.dev`
   CRDs before Helm runs (Helm only installs CRDs on FIRST install, not on
   re-deploy). Source: `local` (bundled manifest in role `files/`) or
   `download`. Then stamps Helm-ownership label + release annotations so the
   chart can adopt them.
6. **`dataengine_deploy`** — runs `zarf init`, creates the three VAST
   namespaces with the `zarf.dev/vast=mutate` label, then runs
   `zarf package deploy` of the DataEngine package. Both zarf calls use
   `async: 900 poll: 15` (15-min ceiling per call). The two surviving
   `command:` tasks have `changed_when:` parsing stdout for true idempotency.

## Configuration knobs

See `inventory/group_vars/all/vars.yml` for the full set. Most important:

| Key | What |
| --- | --- |
| `zarf_packages.source` | `local` / `download` / `upload` |
| `zarf_packages.operator_init_path` | path on operator (upload/files) |
| `zarf_packages.operator_dataengine_path` | path on operator (upload/files) |
| `storage.provisioner` | `local-path` / `vast-csi` / `byo` / `none` |
| `storage.class_name` | which StorageClass to mark default (byo) |
| `vast_namespaces` | which K8s namespaces get the VAST mutator label |
| `inotify_max_user_*` | sysctl tuning targets |

## Uninstall

The historic `99-uninstall.yml` has NOT yet been ported to a role; restore
it from git history if you need destructive cleanup. The equivalent
manual steps:

```bash
zarf destroy --confirm
kubectl delete ns vast-dataengine knative-eventing knative-serving zarf
```
