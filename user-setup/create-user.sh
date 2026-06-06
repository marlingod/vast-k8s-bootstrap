#!/usr/bin/env bash
set -euo pipefail

# ─── EDIT THESE ────────────────────────────────────────────────────────────
NEW_USER="k8s-admin"
NAMESPACE="kube-system"
ROLE="cluster-admin"
API_ENDPOINT="https://10.143.2.242:6443"
OUTPUT_KUBECONFIG="$HOME/.kube/${NEW_USER}.yaml"
EXISTING_KUBECONFIG="$HOME/.kube/config"   # ← USE THE MASTER'S OWN admin.conf
# ───────────────────────────────────────────────────────────────────────────

# Sanity check
[ -r "$EXISTING_KUBECONFIG" ] || { echo "ERROR: $EXISTING_KUBECONFIG not found"; exit 1; }

export KUBECONFIG="$EXISTING_KUBECONFIG"

echo "1) Creating ServiceAccount + ClusterRoleBinding + token Secret..."
kubectl apply -f - <<MANIFEST_END
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NEW_USER}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NEW_USER}-${ROLE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${ROLE}
subjects:
- kind: ServiceAccount
  name: ${NEW_USER}
  namespace: ${NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${NEW_USER}-token
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${NEW_USER}
type: kubernetes.io/service-account-token
MANIFEST_END

echo "2) Waiting for token controller to populate the Secret..."
for i in 1 2 3 4 5; do
if kubectl -n "${NAMESPACE}" get secret "${NEW_USER}-token" \
        -o jsonpath='{.data.token}' 2>/dev/null | grep -q '.'; then
    break
fi
sleep 1
done

echo "3) Extracting token + CA cert..."
TOKEN=$(kubectl -n "${NAMESPACE}" get secret "${NEW_USER}-token" -o jsonpath='{.data.token}' | base64 -d)
CA_B64=$(kubectl -n "${NAMESPACE}" get secret "${NEW_USER}-token" -o jsonpath='{.data.ca\.crt}')

echo "4) Writing kubeconfig to ${OUTPUT_KUBECONFIG}..."
mkdir -p "$(dirname "${OUTPUT_KUBECONFIG}")"
cat > "${OUTPUT_KUBECONFIG}" <<KUBECFG_END
apiVersion: v1
kind: Config
clusters:
  - name: vastde-cluster
    cluster:
      server: ${API_ENDPOINT}
      certificate-authority-data: ${CA_B64}
users:
  - name: ${NEW_USER}
    user:
      token: ${TOKEN}
contexts:
  - name: ${NEW_USER}-ctx
    context:
      cluster: vastde-cluster
      user: ${NEW_USER}
      namespace: default
current-context: ${NEW_USER}-ctx
KUBECFG_END
chmod 600 "${OUTPUT_KUBECONFIG}"

echo
echo "5) Testing the new kubeconfig..."
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl auth whoami
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl get nodes

echo
echo "✓ Done. Use:   export KUBECONFIG=${OUTPUT_KUBECONFIG}"