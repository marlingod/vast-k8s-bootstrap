#!/usr/bin/env bash
set -euo pipefail
umask 077

# Provision a K8s user backed by an X.509 client cert (CSR submitted to the
# cluster's signer). Runs locally on a machine with cluster-admin kubeconfig.
#
# Flags (or env vars): --user, --group, --role, --endpoint, --output, --days

NEW_USER="${NEW_USER:-k8s-cert-admin}"
USER_GROUP="${USER_GROUP:-}"
ROLE="${ROLE:-cluster-admin}"
API_ENDPOINT="${API_ENDPOINT:-}"
OUTPUT_KUBECONFIG="${OUTPUT_KUBECONFIG:-}"
EXISTING_KUBECONFIG="${EXISTING_KUBECONFIG:-$HOME/.kube/config}"
CERT_DAYS="${CERT_DAYS:-365}"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)     NEW_USER="$2"; shift 2 ;;
    --group)    USER_GROUP="$2"; shift 2 ;;
    --role)     ROLE="$2"; shift 2 ;;
    --endpoint) API_ENDPOINT="$2"; shift 2 ;;
    --output)   OUTPUT_KUBECONFIG="$2"; shift 2 ;;
    --days)     CERT_DAYS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "${API_ENDPOINT}" ] || { echo "ERROR: --endpoint required" >&2; exit 2; }
OUTPUT_KUBECONFIG="${OUTPUT_KUBECONFIG:-$HOME/.kube/${NEW_USER}-cert.yaml}"
[ -r "${EXISTING_KUBECONFIG}" ] || { echo "ERROR: ${EXISTING_KUBECONFIG} not found" >&2; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl required" >&2; exit 1; }

export KUBECONFIG="${EXISTING_KUBECONFIG}"
WORKDIR="$(mktemp -d)"; trap 'rm -rf "${WORKDIR}"' EXIT
KEY_FILE="${WORKDIR}/${NEW_USER}.key"; CSR_FILE="${WORKDIR}/${NEW_USER}.csr"
CSR_NAME="${NEW_USER}-csr"
EXPIRATION_SECONDS=$(( CERT_DAYS * 24 * 3600 ))

echo "1) Generating private key + CSR..."
openssl genrsa -out "${KEY_FILE}" 2048 2>/dev/null
SUBJ="/CN=${NEW_USER}"
[ -n "${USER_GROUP}" ] && SUBJ="${SUBJ}/O=${USER_GROUP}"
openssl req -new -key "${KEY_FILE}" -out "${CSR_FILE}" -subj "${SUBJ}"
CSR_B64=$(base64 < "${CSR_FILE}" | tr -d '\n')

echo "2) Submitting CSR ${CSR_NAME}..."
kubectl delete csr "${CSR_NAME}" --ignore-not-found >/dev/null
kubectl apply -f - <<CSR_END
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  request: ${CSR_B64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${EXPIRATION_SECONDS}
  usages:
    - client auth
CSR_END

echo "3) Approving CSR..."
kubectl certificate approve "${CSR_NAME}"

echo "4) Waiting for signer..."
CRT_B64=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  CRT_B64=$(kubectl get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}' 2>/dev/null || true)
  [ -n "${CRT_B64}" ] && break
  sleep 1
done
[ -n "${CRT_B64}" ] || { echo "ERROR: cert was not issued" >&2; exit 1; }

echo "5) ClusterRoleBinding..."
kubectl apply -f - <<RBAC_END
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NEW_USER}-${ROLE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${ROLE}
subjects:
  - kind: User
    name: ${NEW_USER}
    apiGroup: rbac.authorization.k8s.io
RBAC_END

CA_B64=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
if [ -z "${CA_B64}" ]; then
  CA_PATH=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')
  CA_B64=$(base64 < "${CA_PATH}" | tr -d '\n')
fi
KEY_B64=$(base64 < "${KEY_FILE}" | tr -d '\n')

echo "6) Writing kubeconfig to ${OUTPUT_KUBECONFIG}..."
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
      client-certificate-data: ${CRT_B64}
      client-key-data: ${KEY_B64}
contexts:
  - name: ${NEW_USER}-ctx
    context:
      cluster: vast-cluster
      user: ${NEW_USER}
      namespace: default
current-context: ${NEW_USER}-ctx
KUBECFG_END
chmod 600 "${OUTPUT_KUBECONFIG}"

echo "7) Test:"
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl auth whoami
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl get nodes

echo
echo "Done. Cert valid ~${CERT_DAYS} days. Re-run to rotate."
