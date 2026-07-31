# Technical Advisory — VAST DataEngine installation: `zarf init` fails on Kubespray-deployed Kubernetes (IPVS kube-proxy)

**Audience:** Customer platform / Kubernetes administrators
**Applies to:** Kubernetes clusters deployed with Kubespray (or any deployment
where kube-proxy runs in **IPVS** mode), targeted for VAST DataEngine
installation via Zarf.
**Impact:** Blocks DataEngine installation at the first step — the Zarf
in-cluster registry bootstrap (`zarf init`) cannot complete. No workloads are
affected; the failure occurs before any DataEngine component is deployed.
**Validation:** Root cause and **both resolution options below were verified
end-to-end** on a Kubespray-deployed test cluster (Kubespray-current /
Kubernetes v1.36, Calico VXLAN, Zarf v0.60.0), 2026-07-31. Each option's
section states exactly what was tested.

---

## Summary

The VAST DataEngine is delivered as Zarf packages. `zarf init` bootstraps an
in-cluster container registry, and its default mechanism requires each node to
reach a Kubernetes NodePort service via `127.0.0.1`. Clusters whose
kube-proxy runs in **IPVS mode — Kubespray's default —** do not support
localhost NodePort access, so the bootstrap fails with a registry image pull
error. The cluster itself is healthy; only this access pattern is missing.

**Resolution:** run kube-proxy in **iptables** mode (Option A), **or** point
Zarf at an external registry (Option B), which avoids the mechanism entirely.

> ⚠️ **Important caveat found in testing:** on an **existing** cluster,
> changing `kube_proxy_mode` in the Kubespray inventory and re-running
> `cluster.yml` **does not apply the change** — the playbook completes
> successfully but kube-proxy stays in IPVS mode. See Option A for the
> procedures that actually work.

## Symptom

During `zarf init`, the registry deployment fails and `kubectl describe pod`
in the `zarf` namespace shows:

```
Failed to pull image "127.0.0.1:<port>/library/registry:3.0.0":
... dial tcp 127.0.0.1:<port>: connect: connection refused
```

All nodes are `Ready`, the CNI is healthy, and node-to-node connectivity
tests pass — which makes the error look mysterious. It is not a network
fault.

## Technical background

To run a registry inside the cluster, Kubernetes must pull the registry's own
image — from a registry that does not exist yet. `zarf init` solves this by:

1. Writing the seed registry image into the cluster as ConfigMaps (API-only,
   no pulls).
2. Starting a bootstrap pod from an image already cached on a node, which
   serves those ConfigMaps as a temporary, pull-only registry.
3. Publishing that temporary registry on a NodePort reached as
   **`127.0.0.1:<port>`** from every node, so no DNS or routable registry
   address is needed mid-bootstrap.
4. Deploying the permanent registry with its image reference pointing at
   `127.0.0.1:<port>`, so the kubelet pulls it from the temporary one.

Step 3 relies on kube-proxy's **iptables** mode, which supports NodePort
access via localhost. **IPVS mode does not** — NodePorts are bound to the
node's real addresses only, so the pull in step 4 is refused.

## Diagnosis (one command)

```bash
kubectl -n kube-system get cm kube-proxy -o yaml | grep -w mode
```

- `mode: ipvs` → this advisory applies.
- `mode: iptables` (or `""`) → this advisory does not apply; investigate CNI
  health and cross-node routing instead.

## Resolution

### Option A — kube-proxy in iptables mode

*Consideration:* IPVS is sometimes chosen deliberately for very large Service
counts. At typical DataEngine cluster sizes, iptables mode has no practical
drawback.

#### A1 — New / redeployable clusters ✅ *(verified end-to-end)*

Set the mode in the Kubespray inventory **before deploying**:

```yaml
# group_vars/k8s_cluster/k8s-cluster.yml
kube_proxy_mode: iptables
```

Deploy normally, then run `zarf init`.
**Tested result:** a fresh Kubespray deployment with this setting came up in
iptables mode and a default `zarf init` completed successfully — registry
`Running`, no manual steps.

#### A2 — Existing clusters that cannot be redeployed ✅ *(verified end-to-end)*

**Do not rely on a `cluster.yml` re-run** — in testing, re-running the
playbook with `kube_proxy_mode: iptables` set completed without errors and
changed nothing: the cluster remained in IPVS mode (the kube-proxy ConfigMap
is only generated at cluster-creation time). Instead, switch in place:

```bash
# 1. Flip the mode in the kube-proxy ConfigMap
kubectl -n kube-system get cm kube-proxy -o yaml \
  | sed 's/mode: ipvs/mode: iptables/' | kubectl apply -f -

# 2. Restart kube-proxy so it picks the mode up
kubectl -n kube-system rollout restart ds kube-proxy

# 3. On EVERY node, clear IPVS remnants (they otherwise shadow the new rules)
sudo ipvsadm --clear && sudo ip link del kube-ipvs0
```

**Also set `kube_proxy_mode: iptables` in the Kubespray inventory** so the
recorded configuration matches reality and future cluster operations do not
reintroduce IPVS.
**Tested result:** after this switch, `zarf init` completed successfully on
the same cluster that previously failed.
*(Note: the inert `kube-ipvs0` device can survive even a full
`reset.yml`/redeploy cycle; deleting it as in step 3 is harmless.)*

### Option B — external registry, no cluster changes ✅ *(verified end-to-end under IPVS)*

If the cluster configuration cannot be changed at all, `zarf init` can use an
existing registry instead of bootstrapping its own. This bypasses the
localhost NodePort mechanism entirely — **verified working with kube-proxy
still in IPVS mode**, using [ZOT](https://zotregistry.dev) running as a plain
host service outside the cluster:

```bash
zarf init --registry-url <registry-host>:<port> \
          --registry-push-username <user> --registry-push-password <password> \
          --registry-pull-username <user> --registry-pull-password <password> \
          --plain-http -a amd64 --confirm
```

Three prerequisites found in testing — all required:

1. **containerd must trust the registry** on every node. For a plain-HTTP
   registry, create on each node:
   ```
   # /etc/containerd/certs.d/<registry-host>:<port>/hosts.toml
   server = "http://<registry-host>:<port>"
   [host."http://<registry-host>:<port>"]
     capabilities = ["pull", "resolve"]
     skip_verify = true
   ```
   Kubespray's containerd config already enables
   `config_path = /etc/containerd/certs.d`, so the file takes effect without
   restarting containerd. (An HTTPS registry with a trusted certificate needs
   none of this and no `--plain-http`.)
2. **ZOT specifically: enable Docker-manifest compatibility.** ZOT is strict
   OCI by default and rejects Zarf's Docker-format image manifests with
   `HTTP 415 manifest invalid`. In the ZOT config:
   ```json
   "http": { "address": "0.0.0.0", "port": "5000", "compat": ["docker2s2"] }
   ```
   (Verified on ZOT v2.1.18. Docker-tolerant registries — Harbor, Docker
   `registry` — should not need an equivalent, though this was not tested.)
3. **The registry must remain available for the life of the cluster** —
   workload images are pulled from it on every pod start.

**Tested result:** with the above in place, `zarf init --registry-url`
completed on the IPVS-mode cluster; the Zarf agent pods came up pulling
images directly from the external registry, and no in-cluster
`zarf-docker-registry` is deployed in this mode.

### Option C — Zarf registry proxy mode ⚠️ *(not tested)*

Recent Zarf releases offer `--registry-mode=proxy` with a host-network proxy,
which also avoids localhost NodePorts. Check `zarf init --help` in your Zarf
version for flag availability before planning around this option. This path
was **not** exercised in our validation.

## Verification

Pre-flight (before any DataEngine install on a new cluster):

```bash
kubectl -n kube-system get cm kube-proxy -o yaml | grep -w mode   # want: iptables (for Option A)
```

Post-fix:

- Option A: `zarf init` completes; `kubectl get pods -n zarf` shows
  `zarf-docker-registry` `Running`.
- Option B: `zarf init` completes; `kubectl get pods -n zarf` shows the
  agent pods `Running` with images referencing your external registry
  (`kubectl get pods -n zarf -o jsonpath='{.items[*].spec.containers[*].image}'`),
  and **no** `zarf-docker-registry` pod (expected in external mode).

## Support boundary

- The kube-proxy mode is a property of the customer's Kubernetes deployment
  (Kubespray inventory); changing it is a platform-team action.
- VAST provides the DataEngine Zarf packages and this guidance; the external
  registry in Option B, if chosen, is operated by the customer.
- If the symptom persists with `mode: iptables` confirmed, engage VAST
  support with the output of `kubectl get pods -n zarf -o wide` and
  `kubectl describe pod` for the failing registry pod.

## References

- Zarf documentation — the init package: https://docs.zarf.dev/ref/init-package/
- Kubespray — kube-proxy configuration: https://github.com/kubernetes-sigs/kubespray
- ZOT registry: https://zotregistry.dev
