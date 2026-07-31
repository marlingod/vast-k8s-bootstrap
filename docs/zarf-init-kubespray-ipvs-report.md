# Report — `zarf init` failure on a Kubespray cluster (IPVS kube-proxy)

**Date:** 2026-07-31
**Environment:** Kubespray-built Kubernetes (2 nodes: `node1`, `10.143.3.16`),
Calico CNI (VXLAN backend), Zarf v0.60.0, VAST DataEngine packages.
**Status:** Root cause confirmed, fix applied, `zarf init` **verified working**.

---

## 1. How Zarf works (the part that matters here)

Zarf is an air-gap packaging tool: it bundles container images, Helm charts,
and manifests into `.tar.zst` packages and deploys them onto clusters with no
internet access. To do that it needs an **in-cluster container registry** —
which creates a chicken-and-egg problem: *to run a registry, Kubernetes must
pull the registry's own image from a registry that doesn't exist yet.*

`zarf init` breaks the loop in stages (full detail: `docs/zarf-init-flow.md`):

1. **Payload injection** — the seed registry image is split into ConfigMaps
   (pure API writes, no network or registry needed).
2. **Injector pod** — starts from an image *already cached* on a node, glues
   the ConfigMap chunks back together, and serves them as a minimal pull-only
   registry on port 5000.
3. **Localhost NodePort** — the seed registry's Service is published so every
   node reaches it at **`127.0.0.1:<nodeport>`**. This avoids needing DNS or
   a routable registry IP mid-bootstrap.
4. **Real registry** — the persistent `zarf-docker-registry` is deployed with
   its image reference set to `127.0.0.1:<nodeport>/library/registry:3.0.0`;
   the kubelet pulls it *from the seed*, the registry starts on its PVC, all
   package images are pushed in, and the bootstrap scaffolding is torn down.
5. From then on, Zarf's mutating webhook rewrites workload image references
   to the internal registry.

**The load-bearing assumption is stage 3:** that a node can reach a NodePort
service via `127.0.0.1`. That works when kube-proxy runs in **iptables** mode
(kube-proxy sets `route_localnet=1` and DNATs localhost NodePort traffic).

## 2. What failed, and why

### Symptom

`zarf init` failed at stage 4: the `zarf-docker-registry` pod could not pull
`127.0.0.1:<nodeport>/library/registry:3.0.0` — `connection refused`. This is
the same surface error seen on OpenShift/OVN clusters, but the cause here is
different.

### Root cause

**Kubespray deploys kube-proxy in IPVS mode by default**, and IPVS does not
implement the localhost-NodePort path Zarf depends on:

```
$ kubectl -n kube-system get cm kube-proxy -o yaml | grep -w mode
    mode: ipvs
```

Under IPVS, NodePorts are bound to the node's real addresses (via the
`kube-ipvs0` device); traffic to `127.0.0.1:<nodeport>` resolves to nothing,
so the CRI's image pull is refused. The cluster is otherwise perfectly
healthy — which is what makes this failure look mysterious.

### Everything else was ruled out first

| Check | Result | Verdict |
|---|---|---|
| kube-proxy mode | `ipvs` | ❌ root cause |
| CNI health | `calico-node` Running on both nodes | ✅ |
| Calico backend / MTU | VXLAN, `vxlan.calico` MTU 1450 on 1500-MTU NICs | ✅ correctly sized |
| Node-to-node TCP (kubelet 10250) | reachable | ✅ |
| Path MTU (`ping -M do -s 1400`) | 0% loss, no fragmentation needed | ✅ |

## 3. The fix (validated)

kube-proxy was switched from IPVS to iptables mode **in place** — no
Kubespray re-run required for the test:

```bash
# 1. Flip the mode in the kube-proxy ConfigMap
kubectl -n kube-system get cm kube-proxy -o yaml \
  | sed 's/mode: ipvs/mode: iptables/' | kubectl apply -f -

# 2. Restart kube-proxy so it picks the mode up
kubectl -n kube-system rollout restart ds kube-proxy

# 3. On EVERY node, clear IPVS leftovers (they otherwise shadow the new rules)
sudo ipvsadm --clear && sudo ip link del kube-ipvs0

# 4. Re-run the deploy
zarf init ...        # (make zarf)
```

**Result: `zarf init` completed successfully.** The seed registry was
reachable at `127.0.0.1:<nodeport>`, the persistent registry came up, and the
bootstrap proceeded normally.

## 4. Recommendations going forward

The in-place ConfigMap edit is a *validation* fix — a future Kubespray run
reverts it. For durable deployments, pick by constraint:

| Situation | Recommendation |
|---|---|
| Cluster can be (re)deployed or Kubespray re-run | Set `kube_proxy_mode: iptables` in `group_vars/k8s_cluster/k8s-cluster.yml` and run the cluster playbook (then clear IPVS leftovers as above on existing nodes). |
| Cluster must not be touched | Use an **external registry** instead of Zarf's built-in one: `zarf init --registry-url <host>:<port> --registry-push-username … --registry-push-password …`. Skips the localhost machinery entirely; IPVS becomes irrelevant. ZOT is a field-proven choice. |
| Newer Zarf available | `--registry-mode=proxy` with `HOST_NETWORK_PROXY=true` also bypasses the localhost NodePort (hostNetwork socat proxy). Verify the flag exists in your Zarf version first (`zarf init --help`) — it postdates v0.60.0's typical builds. |

**Pre-flight check to add to any Kubespray/customer engagement** (one line,
run before `zarf init`):

```bash
kubectl -n kube-system get cm kube-proxy -o yaml | grep -w mode   # want: iptables
```

## 5. References

- `docs/zarf-init-flow.md` — full stage-by-stage bootstrap internals and
  failure-mode table (including the OpenShift/OVN variant of this symptom).
- `docs/vast-kb-gaps.md` — catalog of gaps between the field and the VAST KB.
- [Zarf issue #2146 — registry NodePort security/behavior](https://github.com/zarf-dev/zarf/issues/2146)
- [Kubespray kube-proxy configuration](https://github.com/kubernetes-sigs/kubespray)
