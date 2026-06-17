# VAST KB gaps & workarounds

This doc catalogs every step we had to add, every workaround we encoded
in a role, and every "the official KB doesn't mention this" lesson learned
while building this collection. Each entry maps **(what we hit) → (what
the VAST KB says) → (where the workaround lives in this codebase)**.

Read this alongside the official VAST documentation:

- [VAST DataEngine landing](https://kb.vastdata.com/documentation/docs/vast-dataengine-1)
- [Enabling Data Engine on a VAST Cluster Tenant](https://kb.vastdata.com/documentation/docs/enabling-data-engine-on-a-vast-cluster-tenant-1#establish-prerequisite-external-services)
- [Steps to Deploy VAST CSI Driver](https://kb.vastdata.com/documentation/docs/steps-to-deploy-vast-csi-driver)

## How to use this doc

- If you're debugging a deployment, search for symptom keywords (e.g. "No such file or directory", "CRD not found", "registry hangs").
- If you're modifying a role, read the linked workaround so you don't accidentally remove the fix.
- If you find a NEW gap, add an entry following the same shape (Gap / KB position / Workaround / Symptom-if-removed / Role).

---

# 1. CSI Driver gaps

## 1.1 NFS client tools must exist on every node that will mount a PVC

| | |
|--|--|
| **Gap** | The CSI driver assumes the host OS has a working `mount.nfs` binary (`nfs-common` on Debian/Ubuntu, `nfs-utils` on RHEL). |
| **KB position** | "Steps to Deploy VAST CSI Driver" mentions NFS but doesn't make the host-side package install a prereq with a fail-loud check. |
| **Workaround** | `roles/nfs_client/` installs the right package per distro, then verifies via `command -v mount.nfs` so a missing binary fails at deploy time instead of at first PVC mount. |
| **Symptom if removed** | `kubelet` PVC mount fails with `mount.nfs: command not found` (or worse, a silent hang while kubelet retries). |

## 1.2 `mount.nfs` path differs across distros

| | |
|--|--|
| **Gap** | On older Debian / Ubuntu, `mount.nfs` is at `/sbin/mount.nfs`. On Ubuntu 24.04 (Noble) and the merged-`/usr` distros, it lives at `/usr/sbin/mount.nfs` and `/sbin` may not symlink the way you expect. |
| **KB position** | Not addressed. |
| **Workaround** | `roles/nfs_client/tasks/main.yml` uses `ansible.builtin.shell: command -v mount.nfs` (via bash so `command` builtin works) instead of `stat`ting a hardcoded path. |
| **Symptom if removed** | False-positive "missing" error on Ubuntu Noble even though `nfs-common` is installed. |

## 1.3 `storage_path` view must allow auto-create of child directories

| | |
|--|--|
| **Gap** | VAST CSI creates one subdirectory per PVC under your view's `storagePath`. The view at that path must be configured to allow create-dir, otherwise VMS API returns "success" but the underlying directory never lands and `kubelet` later fails with **"reason given by server: No such file or directory"** on mount. |
| **KB position** | The "Steps to Deploy VAST CSI Driver" doc covers view creation but doesn't loudly call out the create-dir requirement OR show what the mount-time failure looks like. |
| **Workaround** | None on this side — it's a VMS configuration concern. Documented in `README.md` "Before you start → 1. VAST CSI Driver prerequisites" with a pointer to check the view's "Create Dir" flag. |
| **Symptom if removed** | `kubectl describe pod` events show `MountVolume.SetUp failed for volume ... : mount.nfs: mounting <vip>:/<path>/<pvc-xxx> failed, reason given by server: No such file or directory`. |

## 1.4 VMS user needs specific rights on the tenant

| | |
|--|--|
| **Gap** | The credentials in `vault_vms_username` / `vault_vms_password` must belong to a VMS user with rights to *create file systems, VIP pools, view policies, snapshots, quotas* on the tenant the CSI driver is deployed into. If the user is missing "create-dir" / "manage views" rights, the VMS API call for PVC creation returns success in API bookkeeping but no actual directory is created on disk. |
| **KB position** | The KB doc mentions creating a VMS user but doesn't enumerate exact rights needed. |
| **Workaround** | Documented in `README.md` "Before you start → 1. VAST CSI Driver prerequisites" with the explicit list of required rights. |
| **Symptom if removed** | Same as 1.3 — silent VMS API success, mount-time NFS failure. |

## 1.5 `vms_tenant` is a separate VAST-side concept from K8s `csi_namespace`

| | |
|--|--|
| **Gap** | `csi_namespace` is the K8s namespace the CSI driver runs in (default `vastcsi`). `vms_tenant` is the VAST cluster tenant the driver authenticates **into**. They are unrelated; the CSI driver is "deployed inside a tenant" by means of `vms_tenant` + tenant-scoped credentials, not by the K8s namespace. |
| **KB position** | The docs use "tenant" without clarifying which side it refers to. |
| **Workaround** | `inventory/group_vars/all/vars.yml` has a **"TENANT-SCOPED"** banner specifically calling out which fields change per-VAST-tenant: `vms_endpoint`, `vms_tenant`, `storage_classes.*.viewPolicy`, `storage_classes.*.vipPool` / `vipPoolFQDN`. |
| **Symptom if removed** | A user edits `csi_namespace` thinking they're configuring tenant isolation; the driver still hits the wrong tenant and fails to provision. |

## 1.6 External-snapshotter CRDs are not installed by the VAST CSI chart

| | |
|--|--|
| **Gap** | The VAST CSI Helm chart assumes the `snapshot.storage.k8s.io` CRDs already exist on the cluster. On a vanilla kubeadm cluster they don't. |
| **KB position** | The KB doc mentions snapshots but doesn't say you need to apply the upstream `kubernetes-csi/external-snapshotter` CRDs yourself. |
| **Workaround** | `roles/snapshot_crds/` applies the five external-snapshotter manifests at a pinned version (`snapshot_crds_version` default `v7.0.1`). Gated by `install_snapshot_crds: true` so you can disable it if you've installed CRDs by another mechanism. |
| **Symptom if removed** | VolumeSnapshot CRs are accepted by the API server (no validation) but never trigger any provisioner action. |

---

# 2. DataEngine / Zarf gaps

## 2.1 inotify kernel limits must be raised before pods schedule

| | |
|--|--|
| **Gap** | Knative + KEDA + the VAST operator + 5 telemetry collectors blow past the default kernel `fs.inotify.max_user_instances` (~128) and `max_user_watches` (~8k). Pods CrashLoopBackOff at startup with `inotify_init1: Too many open files`. |
| **KB position** | The DataEngine prerequisites doc mentions inotify in passing but doesn't show the sysctl values or that they must be set on **every** K8s node. |
| **Workaround** | `roles/inotify_limits/` writes a persistent drop-in at `/etc/sysctl.d/99-vast-inotify.conf` with `8192` / `524288` on every host in `k8s_nodes`. Runs **before** zarf init in `playbooks/zarf.yml`. |
| **Symptom if removed** | Random subset of operator / collector pods stuck CrashLoopBackOff; logs show "Too many open files". |

## 2.2 A default StorageClass is mandatory before `zarf init`

| | |
|--|--|
| **Gap** | `zarf init` deploys a seed registry with a PVC. If no default StorageClass is set, the PVC stays `Pending` for ~15 minutes before zarf gives up. |
| **KB position** | The DE prereq doc says "you need storage" but doesn't say "must be marked default" or quantify the hang. |
| **Workaround** | `roles/storage_class/` runs **before** the `dataengine_deploy` role. Branches on `storage.provisioner`: `local-path` (installs rancher), `vast-csi` (no-op, assumes `make csi` set one), `byo` (verify the named class exists, mark default if no default yet), `none` (fail-fast with a clear message). Final assert confirms a default class exists before the role exits. |
| **Symptom if removed** | `zarf init` hangs for ~15 min with no log message, then times out. Subsequent retries hang the same way. |

## 2.3 `zarf init --storage-class` must be passed explicitly

| | |
|--|--|
| **Gap** | Even with a default StorageClass set, the safest bet is to pass `--storage-class <name>` to `zarf init` so the seed registry PVC is pinned to a known class. |
| **KB position** | Not documented at all. |
| **Workaround** | `roles/dataengine_deploy/tasks/main.yml` always passes `--storage-class {{ zarf_init_storage_class }}` (defaults to `storage.class_name`; can be overridden to any key from `storage_classes:` or any other in-cluster class). |
| **Symptom if removed** | `zarf init` may bind to an unexpected class if the cluster default changes between runs. |

## 2.4 knative-operator CRDs must be pre-installed before the DataEngine package

| | |
|--|--|
| **Gap** | Helm's `crds/` directory only installs CRDs on the **first** chart install, never on re-install / re-deploy. If `zarf package remove` ever runs (or someone `kubectl delete`s a CRD), the DataEngine chart deploy fails with `CustomResourceDefinition not found` for `knativeeventings.operator.knative.dev` / `knativeservings.operator.knative.dev`. |
| **KB position** | Not documented. |
| **Workaround** | `roles/knative_crds/` applies the knative-operator CRDs from a bundled manifest (or upstream URL) **before** `dataengine_deploy`. After applying, it also stamps each CRD with `app.kubernetes.io/managed-by: Helm` label + `meta.helm.sh/release-{name,namespace}` annotations so the chart can adopt them. |
| **Symptom if removed** | DataEngine chart deploy fails with `unable to deploy component "vast-knative-operator": knative*.operator.knative.dev: CustomResourceDefinition not found: context deadline exceeded` after ~5 min. |

## 2.5 Pre-existing CRDs must carry Helm ownership labels before chart adopt

| | |
|--|--|
| **Gap** | Even with the knative CRDs present, Helm refuses to "import" them into a chart unless they have the Helm ownership label + release annotations. Otherwise the chart deploy errors: `invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"`. |
| **KB position** | Not documented. |
| **Workaround** | `roles/knative_crds/tasks/main.yml` stamps every required CRD with `app.kubernetes.io/managed-by: Helm`, `meta.helm.sh/release-name: vast-knative-operator`, `meta.helm.sh/release-namespace: vast-dataengine`. Safe to re-run. |
| **Symptom if removed** | Chart deploy fails with the "invalid ownership metadata" error above. |

## 2.6 VAST namespaces need a specific label for the mutating webhook to fire

| | |
|--|--|
| **Gap** | The VAST mutating webhook (which rewrites image refs to the in-cluster Zarf registry for air-gapped operation) only fires on namespaces labeled `zarf.dev/vast=mutate`. Three namespaces need this: `vast-dataengine`, `knative-eventing`, `knative-serving`. |
| **KB position** | Mentioned in the DE doc but easy to miss; not framed as a hard prerequisite. |
| **Workaround** | `roles/dataengine_deploy/tasks/main.yml` creates the three namespaces with the `zarf.dev/vast=mutate` label baked into the manifest, before `zarf package deploy`. List configurable via `vast_namespaces` in `vars.yml`. |
| **Symptom if removed** | DataEngine pods pull from VAST's external registry instead of the in-cluster Zarf one. Works in connected environments; **breaks silently in air-gapped** deployments. |

## 2.7 `zarf.dev/agent=ignore` overrides the VAST mutator label

| | |
|--|--|
| **Gap** | `zarf init` pre-applies `zarf.dev/agent=ignore` to namespaces it sees as existing, which **overrides** our `zarf.dev/vast=mutate` label and bypasses image rewriting. |
| **KB position** | Not documented. |
| **Workaround** | `roles/dataengine_deploy/tasks/main.yml` runs a `kubernetes.core.k8s_json_patch` `op: remove path: /metadata/labels/zarf.dev~1agent` on each VAST namespace right after creating them. `failed_when: false` because the label may not exist. |
| **Symptom if removed** | Mutator label is present but inert — same air-gapped breakage as 2.6. |

## 2.8 Private-registry secret must be synced to every VAST namespace

| | |
|--|--|
| **Gap** | The Zarf agent copies the `zarf/private-registry` secret into a target namespace **on the first mutation only**. After `zarf init` regenerates registry credentials (e.g. on a re-init), the stale secret in vast namespaces causes image pulls to fail with `401 Unauthorized` even with `imagePullSecrets:` set. |
| **KB position** | Not documented. |
| **Workaround** | `roles/dataengine_deploy/tasks/main.yml` (in earlier versions before consolidation — see commit `b678673` for original `04-namespaces.yml`) re-syncs the private-registry secret into every VAST namespace, stripping `resourceVersion`/`uid`/`managedFields` to avoid optimistic-concurrency conflicts. |
| **Symptom if removed** | After a re-init, pods in vast namespaces fail to pull images with HTTP 401. |

## 2.9 Pre-5.4.1-sp2 zarf init package was named differently

| | |
|--|--|
| **Gap** | Older VAST releases shipped the zarf init package as `vast-zarf-mutator-<arch>-<ver>.tar.zst`. Newer releases renamed it to `zarf-init-<arch>-<ver>.tar.zst`. |
| **KB position** | KB article on the rename exists but is easy to miss when consuming old SE-provided bundles. |
| **Workaround** | `roles/dataengine_deploy/tasks/main.yml` has a pre-init task that renames the old filename to the new one if it's present alongside an absent new-name file. Opt out via `legacy_init_rename: false`. |
| **Symptom if removed** | `zarf init` fails with "file not found" against an older bundle. |

## 2.10 `zarf init` and `zarf package deploy` can take longer than 15 minutes

| | |
|--|--|
| **Gap** | On a cold cluster with VAST CSI provisioning the seed-registry PVC, `zarf init` regularly takes 20–30 min. The first deploy of the DataEngine package can take a similar amount of time pulling images. |
| **KB position** | Not documented; no "expected duration" anywhere. |
| **Workaround** | `roles/dataengine_deploy/tasks/main.yml` runs both `zarf init` and `zarf package deploy` with `async: 1800, poll: 15` (30-min ceiling each). `changed_when` and `failed_when` use `default(1)` for `rc` to handle the async-job dict that's returned on timeout (instead of crashing on a missing `.rc` attribute). |
| **Symptom if removed** | At 15 min in, the old code crashed with `'object of type dict has no attribute rc'` — confusing template error masking the actual timeout. |

---

# 3. K8s cluster prerequisites the DE docs assume but don't require

## 3.1 Kubernetes version floor (project policy: ≥ 1.33)

| | |
|--|--|
| **Gap** | The DataEngine + CSI stack assumes a relatively modern K8s API surface. We've set a hard floor of K8s 1.33 for this project. |
| **KB position** | The DE docs mention K8s version compatibility but don't loudly enforce a floor. |
| **Workaround** | `roles/kubeadm_install/tasks/main.yml` opens with an `ansible.builtin.assert: kubernetes_version is version('1.33', '>=')`. Fails loud and early if someone bumps the default down. |
| **Symptom if removed** | Subtle CRD / API failures deep into the DE deploy pipeline. |

## 3.2 Containerd CRI plugin must be enabled

| | |
|--|--|
| **Gap** | The `containerd.io` apt package ships a config that **disables** the CRI plugin (`disabled_plugins = ["cri"]`). kubeadm preflight then fails with `unknown service runtime.v1.RuntimeService`. |
| **KB position** | Not in the VAST docs — this is upstream containerd behavior the DE docs assume you already handled. |
| **Workaround** | `roles/containerd/tasks/main.yml` regenerates the containerd config from defaults, then runs an idempotent `replace` task forcing `disabled_plugins = []`, plus `SystemdCgroup = true` for kubelet cgroup-driver alignment. |
| **Symptom if removed** | `kubeadm init` fails with `unknown service runtime.v1.RuntimeService`. |

## 3.3 inotify limits also matter for kubelet itself

| | |
|--|--|
| **Gap** | The inotify limits raised for the DataEngine workloads (2.1) also help kubelet on dense clusters. They must be set **before** kubelet starts watching ConfigMaps / Secrets. |
| **KB position** | Not in the VAST docs. |
| **Workaround** | `roles/inotify_limits/` runs in `playbooks/zarf.yml` against all `k8s_nodes` — so by the time DE workloads schedule, the sysctl is already persistent. |
| **Symptom if removed** | Heavy ConfigMap churn → kubelet starts losing watches → workload restarts with no obvious root cause. |

## 3.4 Python `kubernetes` library must be on whichever host runs `kubernetes.core` tasks

| | |
|--|--|
| **Gap** | Every `kubernetes.core.k8s*` task imports the `kubernetes` Python lib. On a fresh Ubuntu/RHEL host (or master) it isn't there by default. |
| **KB position** | This is an Ansible-stack concern the VAST docs don't touch. |
| **Workaround** | `roles/python_k8s_client/` installs `python3-pip` + `kubernetes` Python lib via pip. PEP 668 on Ubuntu 24.04+ requires `--break-system-packages --ignore-installed pyyaml` — defaults are set so it Just Works. Runs **before** any other role that uses `kubernetes.core` (kubeadm_master, csi, zarf, users). |
| **Symptom if removed** | First `kubernetes.core.k8s` call fails with `Failed to import the required Python library (kubernetes)`. |

---

# 4. Order-of-operations gaps

## 4.1 `make csi` must run before `make zarf` when using `provisioner: byo`

| | |
|--|--|
| **Gap** | If you set `storage.provisioner: byo` and `storage.class_name: rdu-sc2`, the `storage_class` role expects `rdu-sc2` to already exist on the cluster. With provisioner: byo it does **not** create the class itself — `make csi` does that via the VAST CSI Helm chart. |
| **KB position** | Not framed as an order requirement in the KB. |
| **Workaround** | `roles/storage_class/tasks/main.yml`'s `Verify named StorageClass exists` is now an `ansible.builtin.assert` with a detailed `fail_msg` that lists: which classes exist, which classes are defined in `storage_classes:`, and three concrete fixes including "run `make csi` first". |
| **Symptom if removed** | Cryptic `failed_when expression evaluated to True` with no diagnostic info. |

## 4.2 Default tag of `make site` runs k8s + csi + zarf + users in dependency order

| | |
|--|--|
| **Gap** | If you `make zarf` against a cluster that doesn't have CSI yet (provisioner: byo + class doesn't exist), it fails at storage_class. The dependency isn't enforced by the playbook; it's enforced by the `--tags` you choose. |
| **KB position** | N/A — this is our playbook structure. |
| **Workaround** | `make site` runs the full chain in the right order. Documented in the README Quick Start. For partial runs, the Tags section of the README shows what each tag depends on. |

---

# 5. `--check` mode pitfalls (development / dry-run only)

These don't affect real deploys but make `make check` against a fresh
cluster useless without workarounds. Useful when iterating on the playbook.

| Gap | Workaround |
|--|--|
| Adding an apt repo simulates in `--check` but doesn't write the source file, so the next `apt install <pkg-from-repo>` fails | `check_mode: false` on Docker/K8s GPG-key + repo-add tasks in `roles/containerd/` and `roles/kubeadm_install/` |
| `dpkg --set-selections hold kubelet` fails in `--check` because kubelet was only simulated as installed | `when: kubelet_bin.stat.exists or not ansible_check_mode` on the hold + systemd-enable tasks |
| `kubeadm init` simulates → no `admin.conf` → every downstream task fails | Stat-guard around the post-init tasks in `roles/kubeadm_master/` |
| `kubeadm join` needs `./k8s-join-command.sh` that the master never fetched | `roles/kubeadm_worker/` has an explicit `ansible.builtin.fail` with three diagnostic causes |
| CSI / Zarf / Users plays all need `/etc/kubernetes/admin.conf` to talk to the API | `pre_tasks:` in each playbook stats admin.conf and `meta: end_play` if missing in check mode |

---

# 6. Tooling / repo pitfalls (not VAST-related, but bit us)

| Gap | Workaround |
|--|--|
| `command -v X` doesn't work with `ansible.builtin.command` (`command` is a shell builtin) | Use `ansible.builtin.shell` with `executable: /bin/bash`, or `stat` an absolute path |
| `kubernetes.core.k8s` with `src:` looks on the **target** for the file, not the controller | Use `definition: "{{ lookup('file', ...) \| from_yaml_all \| list }}"` so the controller reads the file and the resource defs travel as module args |
| `selectattr` on an annotation key containing dots / slashes interprets the dots as nested attribute access | Use `(annotations \| default({})).get('key.with.dots/slash')` inside `{% for %}` loops; **do not** use `community.general.json_query` (pure-Jinja preference) |
| `delegate_to: localhost` inherits the play-level `become: true`, prompting for sudo on the operator's Mac | Always add `become: false` to delegated tasks |
| Tracked config files (vars.yml) collide with local edits on every `git pull` | Gitignore the live file; ship a tracked `.example` template; bootstrap via `make bootstrap` |
| PEP 668 on Ubuntu 24.04+ blocks `pip install` into system Python | Default `pip` args include `--break-system-packages --ignore-installed pyyaml` |
| `make vault-edit` on a not-yet-encrypted vault.yml fails with a cryptic ansible error | New `make vault-encrypt` for first-time; `make vault-edit` now self-diagnoses |

---

## Updating this doc

If you find a new gap during a deploy:

1. Add an entry to the relevant section (numbered to keep ordering stable).
2. Use the four-row table shape: Gap / KB position / Workaround / Symptom-if-removed.
3. Link the role file path so a reader can jump to the implementation.
4. Commit message: `docs(kb-gaps): add <short description>`.

Aim is to keep this doc grep-able by error string. When VAST publishes
updated KB docs that close a gap, **don't delete the entry** — replace
the "KB position" row with a link to the new VAST doc and note that the
workaround can be removed once everyone is on the new VAST version.
