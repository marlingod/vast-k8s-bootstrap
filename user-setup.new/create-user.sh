#!/usr/bin/env bash
set -euo pipefail
umask 077

# Provision a ServiceAccount-backed K8s user + kubeconfig with a long-lived
# bearer token. Runs locally on a machine that has cluster-admin kubeconfig.
#
# Override defaults via env vars or CLI flags:
#   NEW_USER, NAMESPACE, ROLE, API_ENDPOINT, OUTPUT_KUBECONFIG
#   --user, --namespace, --role, --endpoint, --output

NEW_USER="${NEW_USER:-k8s-admin}"
NAMESPACE="${NAMESPACE:-kube-system}"
ROLE="${ROLE:-cluster-admin}"
API_ENDPOINT="${API_ENDPOINT:-}"
OUTPUT_KUBECONFIG="${OUTPUT_KUBECONFIG:-}"
EXISTING_KUBECONFIG="${EXISTING_KUBECONFIG:-$HOME/.kube/config}"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)      NEW_USER="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --role)      ROLE="$2"; shift 2 ;;
    --endpoint)  API_ENDPOINT="$2"; shift 2 ;;
    --output)    OUTPUT_KUBECONFIG="$2"; shift 2 ;;
    -h|--help)
      sed -n '4,15p' "$0" >&2
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "${API_ENDPOINT}" ] || { echo "ERROR: --endpoint or \$API_ENDPOINT required (e.g. https://10.0.0.1:6443)" >&2; exit 2; }
OUTPUT_KUBECONFIG="${OUTPUT_KUBECONFIG:-$HOME/.kube/${NEW_USER}.yaml}"

[ -r "${EXISTING_KUBECONFIG}" ] || { echo "ERROR: ${EXISTING_KUBECONFIG} not found" >&2; exit 1; }
export KUBECONFIG="${EXISTING_KUBECONFIG}"

echo "1) ServiceAccount + ClusterRoleBinding + token Secret..."
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

echo "2) Waiting for token controller..."
for _ in 1 2 3 4 5; do
  if kubectl -n "${NAMESPACE}" get secret "${NEW_USER}-token" \
       -o jsonpath='{.data.token}' 2>/dev/null | grep -q '.'; then break; fi
  sleep 1
done

TOKEN=$(kubectl -n "${NAMESPACE}" get secret "${NEW_USER}-token" -o jsonpath='{.data.token}' | base64 -d)
CA_B64=$(kubectl -n "${NAMESPACE}" get secret "${NEW_USER}-token" -o jsonpath='{.data.ca\.crt}')

echo "3) Writing kubeconfig to ${OUTPUT_KUBECONFIG}..."
mkdir -p "$(dirname "${OUTPUT_KUBECONFIG}")"
cat > "${OUTPUT_KUBECONFIG}" <<KUBECFG_END
apiVersion: v1
kind: Config
clusters:
  - name: vast-cluster
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
      cluster: vast-cluster
      user: ${NEW_USER}
      namespace: default
current-context: ${NEW_USER}-ctx
KUBECFG_END
chmod 600 "${OUTPUT_KUBECONFIG}"

echo "4) Test:"
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl auth whoami
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl get nodes

echo
echo "Done. export KUBECONFIG=${OUTPUT_KUBECONFIG}"
