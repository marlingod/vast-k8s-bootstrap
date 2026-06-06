# K8s cluster bootstrap (kubeadm + Flannel)

Roles consumed by `playbooks/k8s_cluster.yml`:

1. `common_prereqs` — waits for apt-daily / unattended-upgrades, disables those
   timers for the run, refreshes the cache. Runs on every host first.
2. `clustershell` — installs clush + writes `/etc/clustershell/groups.d/local.cfg`
   from inventory groups so `clush -g all 'hostname'` works after deploy.
3. `containerd` — swap off + kernel modules + sysctl + containerd from Docker's
   repo. The containerd config is regenerated and then patched: CRI is
   forced enabled (`disabled_plugins = []`), `SystemdCgroup = true`. A
   handler restarts containerd if any of those change.
4. `kubeadm_install` — registers `pkgs.k8s.io` repo for `v{{ kubernetes_version }}`
   then installs kubeadm/kubelet/kubectl and holds the packages.
5. `kubeadm_master` — guarded by stat of `/etc/kubernetes/admin.conf`. Runs
   `kubeadm init` with `--node-name {{ inventory_hostname }}` so cloned-image
   nodes don't collide. Installs Flannel CNI via the `kubernetes.core.k8s`
   module (no more `kubectl apply`). Generates a join token and fetches it
   to the local control machine.
6. `kubeadm_worker` — guarded by stat of `/etc/kubernetes/kubelet.conf`. Copies
   the fetched join script and runs it with `--node-name`.
7. `firewall_k8s` — opens K8s ports on firewalld OR ufw if either is active.

## Common changes

**Change a node IP** — edit `inventory/hosts.ini`. Nothing else references
the IP directly (`hostvars[inventory_hostname].ansible_host` is used
everywhere). If the master IP changes, you must `kubeadm reset` because
cluster certs are bound to the IP.

**Bump K8s minor** — edit `kubernetes_version` in `inventory/group_vars/all/vars.yml`.
This playbook does NOT perform in-place upgrades; for that, use
`kubeadm upgrade plan`.

**Swap CNI** — replace the `Install Flannel CNI` task in
`roles/kubeadm_master/tasks/main.yml`. Update `pod_network_cidr` if the
new CNI's default differs (Calico's does).

**Add a worker** — append the row to `[workers]` in `hosts.ini`, then
`make k8s` (idempotent; only the new node is touched).

## State on disk after deploy

| Path (master) | What |
| --- | --- |
| `/etc/kubernetes/admin.conf` | cluster-admin kubeconfig |
| `/home/{{ ansible_user }}/.kube/config` | copy of admin.conf for the SSH user |
| `/home/{{ ansible_user }}/k8s-join-command.sh` | worker join command + token |
| `/var/lib/etcd/` | cluster state |
| `<repo>/k8s-join-command.sh` | join script fetched to local machine |
