# VAST DataEngine — Zarf install

Standalone, independently-testable ansible module for installing the Zarf-packaged
VAST DataEngine onto a Kubernetes cluster.

Source-of-truth KB:
[Enabling DataEngine on a VAST Cluster Tenant](https://kb.vastdata.com/documentation/docs/enabling-data-engine-on-a-vast-cluster-tenant-1)
— this module implements the "Preparing Kubernetes Clusters" section verbatim,
plus a `02-storage-class.yml` opt-in that handles the documented
"`zarf init` needs a default StorageClass; otherwise pass `--storage-class`" caveat.

Replaces `src/vastde_orch/clients/kube.py` + `src/vastde_orch/enablement/k8s_bootstrap.py`
from the `vastde-orch` Python project. Pull this module out when you want to:

- Test the K8s bootstrap independently of the VMS-side enablement
- Hand off to a coworker who's only doing cluster setup
- Run it from CI

## Structure

```
zarf/
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini                # which hosts to target
│   ├── group_vars/all.yml.example   # creds + versions + paths (copy → all.yml)
│   ├── site.yml                     # imports 00..05 in order
│   ├── 00-inotify-limits.yml        # sysctl tuning on all K8s nodes
│   ├── 01-install-zarf.yml          # download + install zarf binary on controller
│   ├── 01b-fetch-packages.yml       # ensure the two VAST .tar.zst packages exist (download + extract if missing)
│   ├── 02-storage-class.yml         # ensure a default StorageClass (local-path)
│   ├── 03-zarf-init.yml             # zarf init the cluster
│   ├── 04-namespaces.yml            # create + label vast-dataengine, knative-eventing, knative-serving
│   ├── 04b-knative-crds.yml         # install knative-operator CRDs (Helm doesn't manage them reliably)
│   ├── 05-deploy-dataengine.yml     # zarf package deploy
│   └── 06-verify.yml                # smoke test (opt-in, not in site.yml)
└── packages/                        # gitignored — drop zarf .tar.zst files here
```

## Prerequisites

| | |
|---|---|
| Kubernetes cluster | Reachable from the `zarf_controller` host, `kubectl` already configured (kubeconfig in place) |
| Two Zarf packages | `zarf-init-<arch>-<version>.tar.zst` + `zarf-package-dataengine-<arch>-<version>.tar.zst`. VAST ships them inside `vast_dataengine_release_<N>_<pipeline>.tar.gz`. Two options: (a) drop them into `packages/` manually + leave `zarf_packages.source=local`, or (b) set `zarf_packages.source=download` + `zarf_packages.bundle_url=<SE-provided URL>` and `01b-fetch-packages.yml` will download + extract for you. |
| SSH access | To every host in `inventory.ini`, with sudo or passwordless-sudo |
| Ansible | 2.16+ on the operator host (where you run `ansible-playbook`) |

## Setup

```bash
cd ansible
cp group_vars/all.yml.example group_vars/all.yml
# Edit all.yml — fill in ansible_password / ansible_become_password,
# set zarf_init_package_path + zarf_dataengine_package_path to your local files
```

Edit `inventory.ini` to point at your master + worker IPs.

## Run

```bash
# Full install (all 6 numbered playbooks, in order)
ansible-playbook -i inventory.ini site.yml

# Re-run a single step
ansible-playbook -i inventory.ini 03-zarf-init.yml

# Smoke test (after site.yml succeeds)
ansible-playbook -i inventory.ini 06-verify.yml
```

## Idempotency

Every play checks for "already done" state before mutating:

| Play | Skip condition |
|---|---|
| 00 inotify | sysctl values already meet target |
| 01 install zarf | `zarf` on PATH (and `zarf_detect_existing: true`) |
| 02 storage class | a default StorageClass already exists |
| 03 zarf init | `zarf` namespace exists on the cluster |
| 04 namespaces | namespaces already exist (label is re-applied with `--overwrite`) |
| 05 package deploy | zarf itself diffs and only updates what changed |

Safe to re-run after partial failures.

## Knobs to know

In `group_vars/all.yml`:

| Variable | Default | Notes |
|---|---|---|
| `storage.provisioner` | `local-path` | `local-path` / `vast-csi` / `byo` / `none` (see `all.yml.example` comments) |
| `storage.detect` | `true` | if any default StorageClass already exists, skip everything in `02-storage-class.yml` |
| `storage.class_name` | `local-path` | the SC name passed to `zarf init --storage-class`; must match what the provisioner creates |
| `storage.local_path.source` | `local` | `local` (apply bundled `manifests/local-path-storage-*.yaml` — no internet needed) / `download` (fetch from rancher's GitHub at run time) |
| `storage.local_path.manifest_path` | `manifests/local-path-storage-v0.0.32.yaml` | only used when `source: local`; path is relative to the `ansible/` dir |
| `storage.local_path.version` | `v0.0.32` | only used when `source: download` |
| `knative_crds.source` | `local` | `local` (bundled `manifests/knative-operator-crds-*.yaml`) / `download` (fetch upstream operator.yaml) — installed BEFORE `vast-knative-operator` chart deploy because Helm's `crds/` directory isn't re-installed reliably |
| `knative_crds.manifest_path` | `manifests/knative-operator-crds-v1.17.1.yaml` | only used when `source: local` |
| `knative_crds.version` | `knative-v1.17.1` | only used when `source: download` |
| `zarf_packages.source` | `local` | `local` (require both .tar.zst in `dir`) / `download` (fetch outer .tar.gz from `bundle_url` if missing) |
| `zarf_packages.dir` | `./packages` | where the .tar.zst files live (and where the outer bundle gets extracted) |
| `zarf_packages.bundle_url` | `""` | only used when `source: download`; SE-provided URL to the outer `vast_dataengine_release_*.tar.gz` |
| `zarf_detect_existing` | `true` | set to `false` to force re-download of the zarf binary |
| `legacy_init_rename` | `true` | pre-5.4.1-sp2 file-rename quirk (safe to leave on; no-op otherwise) |
| `vast_namespaces` | `[vast-dataengine, knative-eventing, knative-serving]` | rare to change |
| `inotify_max_user_instances` | `8192` | matches the VAST docs minimum |
| `inotify_max_user_watches` | `524288` | matches the VAST docs minimum |

### Storage provisioner choices

| Value | What 02-storage-class.yml does | When to use |
|---|---|---|
| `local-path` | `kubectl apply` rancher's local-path-provisioner, then mark its SC default | Lab/dev. Pod-local volumes; not for prod. |
| `vast-csi` | No-op (just verifies a default SC exists post-step) | Prod. Pair with the `csidriver` ansible module that ran first. |
| `byo` | Verify `storage.class_name` exists; mark it default if no default exists | "I already installed Longhorn / OpenEBS / EBS / etc." |
| `none` | Fail-fast if no default SC exists | Strict envs where you want the playbook to refuse to proceed. |

## Known gotchas

- **`zarf init` hangs ~15 min if there is no default StorageClass.** Play 02 handles this — but if you set `storage_provisioner: none`, you must have a default StorageClass already.
- **The zarf packages are not in the public Zarf release.** They come from the VAST SE. Drop them into `packages/` (gitignored).
- **The DataEngine package is large.** Plays 03 and 05 use `async: 900, poll: 15` to allow up to 15 minutes per step without losing the SSH session.
