#!/usr/bin/env bash
set -euo pipefail

# ─── EDIT THESE ────────────────────────────────────────────────────────────
NEW_USER="malin-admin"
USER_GROUP=""                              # optional, e.g. "system:masters" (becomes O= in cert)
ROLE="cluster-admin"
API_ENDPOINT="https://10.143.2.247:6443"
OUTPUT_KUBECONFIG="$HOME/.kube/${NEW_USER}-cert.yaml"
EXISTING_KUBECONFIG="$HOME/.kube/config"   # ← USE THE MASTER'S OWN admin.conf
CERT_DAYS=365                              # client cert validity (in seconds for CSR)
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
# ───────────────────────────────────────────────────────────────────────────

# Sanity checks
[ -r "$EXISTING_KUBECONFIG" ] || { echo "ERROR: $EXISTING_KUBECONFIG not found"; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl is required"; exit 1; }

export KUBECONFIG="$EXISTING_KUBECONFIG"

CSR_NAME="${NEW_USER}-csr"
KEY_FILE="${WORKDIR}/${NEW_USER}.key"
CSR_FILE="${WORKDIR}/${NEW_USER}.csr"
CRT_FILE="${WORKDIR}/${NEW_USER}.crt"

echo "1) Generating private key + CSR for CN=${NEW_USER}${USER_GROUP:+, O=${USER_GROUP}}..."
openssl genrsa -out "${KEY_FILE}" 2048 2>/dev/null
SUBJ="/CN=${NEW_USER}"
[ -n "${USER_GROUP}" ] && SUBJ="${SUBJ}/O=${USER_GROUP}"
openssl req -new -key "${KEY_FILE}" -out "${CSR_FILE}" -subj "${SUBJ}"

CSR_B64=$(base64 < "${CSR_FILE}" | tr -d '\n')
EXPIRATION_SECONDS=$(( CERT_DAYS * 24 * 3600 ))

echo "2) Submitting CertificateSigningRequest ${CSR_NAME}..."
# Delete any stale CSR with the same name (CSRs are cluster-scoped, immutable once approved)
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

echo "4) Waiting for the signer to issue the certificate..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  CRT_B64=$(kubectl get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}' 2>/dev/null || true)
  [ -n "${CRT_B64}" ] && break
  sleep 1
done
[ -n "${CRT_B64}" ] || { echo "ERROR: certificate was not issued in time"; exit 1; }
echo "${CRT_B64}" | base64 -d > "${CRT_FILE}"

echo "5) Creating ClusterRoleBinding ${NEW_USER}-${ROLE} (subject kind: User)..."
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

echo "6) Extracting cluster CA from current kubeconfig..."
CURRENT_CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CA_B64=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
if [ -z "${CA_B64}" ]; then
  CA_PATH=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')
  [ -r "${CA_PATH}" ] || { echo "ERROR: cannot read cluster CA (${CA_PATH})"; exit 1; }
  CA_B64=$(base64 < "${CA_PATH}" | tr -d '\n')
fi

KEY_B64=$(base64 < "${KEY_FILE}" | tr -d '\n')

echo "7) Writing kubeconfig to ${OUTPUT_KUBECONFIG}..."
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
      client-certificate-data: ${CRT_B64}
      client-key-data: ${KEY_B64}
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
echo "8) Testing the new kubeconfig..."
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl auth whoami
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl get nodes

echo
echo "✓ Done. Use:   export KUBECONFIG=${OUTPUT_KUBECONFIG}"
echo "  Cert valid for ~${CERT_DAYS} days. Re-run this script to rotate."
