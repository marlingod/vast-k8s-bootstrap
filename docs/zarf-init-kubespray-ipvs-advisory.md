# Technical Advisory — VAST DataEngine installation: `zarf init` fails on Kubespray-deployed Kubernetes (IPVS kube-proxy)

**Audience:** Customer platform / Kubernetes administrators
**Applies to:** Kubernetes clusters deployed with Kubespray (or any deployment
where kube-proxy runs in **IPVS** mode), targeted for VAST DataEngine
installation via Zarf.
**Impact:** Blocks DataEngine installation at the first step — the Zarf
in-cluster registry bootstrap (`zarf init`) cannot complete. No workloads are
affected; the failure occurs before any DataEngine component is deployed.
**Validation:** Root cause and resolution verified on a Kubespray-deployed
test cluster (Calico CNI, Zarf v0.60.0), 2026-07-31.

---

## Summary

The VAST DataEngine is delivered as Zarf packages. `zarf init` bootstraps an
in-cluster container registry, and its default mechanism requires each node to
reach a Kubernetes NodePort service via `127.0.0.1`. Clusters whose
kube-proxy runs in **IPVS mode — Kubespray's default —** do not support
localhost NodePort access, so the bootstrap fails with a registry image pull
error. The cluster itself is healthy; only this access pattern is missing.

**Resolution:** run kube-proxy in **iptables** mode (a one-line Kubespray
setting), **or** point Zarf at an external registry, which avoids the
mechanism entirely. Both options are detailed below.

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

### Option A (recommended) — deploy kube-proxy in iptables mode

In the Kubespray inventory, set:

```yaml
# group_vars/k8s_cluster/k8s-cluster.yml
kube_proxy_mode: iptables
```

- For a new cluster: deploy normally; no further action.
- For an existing cluster: re-run the Kubespray cluster playbook, then clear
  IPVS remnants on every node so they do not shadow the new rules:

  ```bash
  sudo ipvsadm --clear && sudo ip link del kube-ipvs0
  ```

Then run `zarf init` (or re-run the DataEngine installation) normally.

*Consideration:* IPVS is sometimes chosen deliberately for very large Service
counts. At typical DataEngine cluster sizes, iptables mode has no practical
drawback.

### Option B — external registry (no cluster changes)

If the cluster configuration cannot be changed, `zarf init` can use an
existing registry instead of bootstrapping its own:

```bash
zarf init --registry-url <registry-host>:<port> \
          --registry-push-username <user> \
          --registry-push-password <password> \
          -a amd64
```

Any OCI-compliant registry reachable from all nodes works (for example
[ZOT](https://zotregistry.dev), Harbor, or an existing corporate registry).
This bypasses the localhost NodePort mechanism entirely, so the kube-proxy
mode becomes irrelevant. The registry must remain available for the life of
the cluster (workload images are pulled from it on every pod start).

### Option C — Zarf registry proxy mode (newer Zarf versions)

Recent Zarf releases offer `--registry-mode=proxy` with a host-network proxy,
which also avoids localhost NodePorts. Check `zarf init --help` in your Zarf
version for flag availability before planning around this option.

## Verification

Pre-flight (before any DataEngine install on a new cluster):

```bash
kubectl -n kube-system get cm kube-proxy -o yaml | grep -w mode   # expect: iptables
```

Post-fix: `zarf init` completes; `kubectl get pods -n zarf` shows the
`zarf-docker-registry` pod `Running`.

## Support boundary

- The kube-proxy mode is a property of the customer's Kubernetes deployment
  (Kubespray inventory); changing it is a platform-team action.
- VAST provides the DataEngine Zarf packages and this guidance; the external
  registry in Option B, if chosen, is operated by the customer.
- If the symptom persists with `mode: iptables` confirmed, engage VAST
  support with the output of `kubectl get pods -n zarf -o wide` and
  `kubectl describe pod` for the failing registry pod.

---

## Appendix — in-place mode switch (diagnostic use only)

The following switches kube-proxy to iptables **without** re-running
Kubespray. It was used to validate the root cause in a lab and is suitable
for test clusters. **Do not use as the permanent fix on production** — the
change is reverted by the next Kubespray run, leaving the cluster in a state
that disagrees with its inventory.

```bash
kubectl -n kube-system get cm kube-proxy -o yaml \
  | sed 's/mode: ipvs/mode: iptables/' | kubectl apply -f -
kubectl -n kube-system rollout restart ds kube-proxy
# then on EVERY node:
sudo ipvsadm --clear && sudo ip link del kube-ipvs0
```

## References

- Zarf documentation — the init package: https://docs.zarf.dev/ref/init-package/
- Kubespray — kube-proxy configuration: https://github.com/kubernetes-sigs/kubespray
- ZOT registry: https://zotregistry.dev
