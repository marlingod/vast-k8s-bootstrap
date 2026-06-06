#!/usr/bin/env bash
set -euo pipefail

# Same SSH-driven CSR flow as create-user-cert-remote.sh, but instead of writing a
# kubeconfig the output is a directory containing the CA cert, the client cert, and
# the client key in BOTH PEM and base64 form.

# ─── EDIT THESE ────────────────────────────────────────────────────────────
NEW_USER="bill-admin"
USER_GROUP=""                              # optional, becomes O= in cert (e.g. "system:masters")
ROLE="cluster-admin"

SSH_USER="vastdata"                            # SSH login on the master node
SSH_HOST="10.143.2.234"
SSH_PASSWORD="vastdata"                            # leave empty to use key auth (recommended).
                                           # If set, requires `sshpass` (brew install hudochenkov/sshpass/sshpass).
                                           # ⚠ Storing a password in plaintext is risky — prefer SSH keys.
SUDO_PASSWORD=""                           # leave empty to reuse SSH_PASSWORD. Set to "" + SSH_USER=root,
                                           # or configure NOPASSWD sudo on the remote, to skip sudo prompt entirely.
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
REMOTE_KUBECONFIG="/etc/kubernetes/admin.conf"

API_ENDPOINT="https://10.143.2.234:6443"   # kube-apiserver reachable from THIS machine (used only for /healthz probe)
OUTPUT_DIR="$HOME/.kube/${NEW_USER}-certs" # where the PEM + base64 files land
CERT_DAYS=365
# ───────────────────────────────────────────────────────────────────────────

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

KEY_FILE="${WORKDIR}/${NEW_USER}.key"
CSR_FILE="${WORKDIR}/${NEW_USER}.csr"
REMOTE_OUT="${WORKDIR}/remote.out"
CSR_NAME="${NEW_USER}-csr"
EXPIRATION_SECONDS=$(( CERT_DAYS * 24 * 3600 ))

# Local prerequisites
command -v openssl >/dev/null  || { echo "ERROR: openssl is required";  exit 1; }
command -v ssh     >/dev/null  || { echo "ERROR: ssh is required";      exit 1; }

SSH_TARGET="${SSH_USER}@${SSH_HOST}"
if [ -n "${SSH_PASSWORD}" ]; then
  command -v sshpass >/dev/null || {
    echo "ERROR: SSH_PASSWORD is set but 'sshpass' is not installed."
    echo "       Install it (macOS: brew install hudochenkov/sshpass/sshpass) or clear SSH_PASSWORD to use key auth."
    exit 1
  }
  export SSHPASS="${SSH_PASSWORD}"
  SSH_CMD=(sshpass -e ssh)
else
  SSH_CMD=(ssh)
fi

: "${SUDO_PASSWORD:=${SSH_PASSWORD}}"
if [ "${SSH_USER}" = "root" ]; then
  REMOTE_INVOKE='bash -s'
  SUDO_STDIN_PREFIX=""
elif [ -n "${SUDO_PASSWORD}" ]; then
  REMOTE_INVOKE="sudo -S -p '' bash -s"
  SUDO_STDIN_PREFIX="${SUDO_PASSWORD}"$'\n'
else
  REMOTE_INVOKE='sudo -n bash -s'
  SUDO_STDIN_PREFIX=""
fi

echo "1) Probing apiserver ${API_ENDPOINT}/healthz..."
if ! curl --max-time 5 -sk -o /dev/null -w '%{http_code}\n' "${API_ENDPOINT}/healthz" | grep -q '^200$'; then
  echo "   WARNING: ${API_ENDPOINT}/healthz did not return 200 from this host (continuing — SSH path is what matters)."
fi

echo "2) Probing SSH to ${SSH_TARGET}..."
"${SSH_CMD[@]}" ${SSH_OPTS} "${SSH_TARGET}" 'true' \
  || { echo "ERROR: cannot SSH to ${SSH_TARGET}"; exit 1; }

echo "3) Generating private key + CSR locally (CN=${NEW_USER}${USER_GROUP:+, O=${USER_GROUP}})..."
openssl genrsa -out "${KEY_FILE}" 2048 2>/dev/null
SUBJ="/CN=${NEW_USER}"
[ -n "${USER_GROUP}" ] && SUBJ="${SUBJ}/O=${USER_GROUP}"
openssl req -new -key "${KEY_FILE}" -out "${CSR_FILE}" -subj "${SUBJ}"
CSR_B64=$(base64 < "${CSR_FILE}" | tr -d '\n')

echo "4) Submitting CSR + ClusterRoleBinding on ${SSH_TARGET} (private key never leaves this machine)..."
{
  [ -n "${SUDO_STDIN_PREFIX}" ] && printf '%s' "${SUDO_STDIN_PREFIX}"
  cat <<REMOTE
set -euo pipefail
export KUBECONFIG="${REMOTE_KUBECONFIG}"

CSR_NAME="${CSR_NAME}"
NEW_USER="${NEW_USER}"
ROLE="${ROLE}"
CSR_B64="${CSR_B64}"
EXPIRATION_SECONDS="${EXPIRATION_SECONDS}"

kubectl delete csr "\${CSR_NAME}" --ignore-not-found >/dev/null

kubectl apply -f - >/dev/null <<CSR_END
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: \${CSR_NAME}
spec:
  request: \${CSR_B64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: \${EXPIRATION_SECONDS}
  usages:
    - client auth
CSR_END

kubectl certificate approve "\${CSR_NAME}" >/dev/null

CRT_B64=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  CRT_B64=\$(kubectl get csr "\${CSR_NAME}" -o jsonpath='{.status.certificate}' 2>/dev/null || true)
  [ -n "\${CRT_B64}" ] && break
  sleep 1
done
if [ -z "\${CRT_B64}" ]; then
  echo "REMOTE-ERROR: certificate was not issued in time" >&2
  exit 1
fi

kubectl apply -f - >/dev/null <<RBAC_END
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: \${NEW_USER}-\${ROLE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: \${ROLE}
subjects:
  - kind: User
    name: \${NEW_USER}
    apiGroup: rbac.authorization.k8s.io
RBAC_END

CA_B64=\$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
if [ -z "\${CA_B64}" ]; then
  CA_PATH=\$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')
  [ -z "\${CA_PATH}" ] && CA_PATH=/etc/kubernetes/pki/ca.crt
  CA_B64=\$(base64 < "\${CA_PATH}" | tr -d '\n')
fi

echo "---SIGNED-CERT-B64---"
echo "\${CRT_B64}"
echo "---CA-CERT-B64---"
echo "\${CA_B64}"
echo "---END---"
REMOTE
} | "${SSH_CMD[@]}" ${SSH_OPTS} "${SSH_TARGET}" "${REMOTE_INVOKE}" >"${REMOTE_OUT}"

echo "5) Parsing remote output..."
awk '/^---SIGNED-CERT-B64---$/{flag="crt"; next}
     /^---CA-CERT-B64---$/{flag="ca";  next}
     /^---END---$/{flag=""; next}
     flag=="crt"{print > "'"${WORKDIR}/crt.b64"'"}
     flag=="ca" {print > "'"${WORKDIR}/ca.b64"'"}' "${REMOTE_OUT}"

CRT_B64=$(tr -d '\n' < "${WORKDIR}/crt.b64" 2>/dev/null || true)
CA_B64=$( tr -d '\n' < "${WORKDIR}/ca.b64"  2>/dev/null || true)
[ -n "${CRT_B64}" ] || { echo "ERROR: did not receive signed cert from remote"; cat "${REMOTE_OUT}"; exit 1; }
[ -n "${CA_B64}"  ] || { echo "ERROR: did not receive CA cert from remote";    cat "${REMOTE_OUT}"; exit 1; }

KEY_B64=$(base64 < "${KEY_FILE}" | tr -d '\n')

echo "6) Writing PEM + base64 outputs to ${OUTPUT_DIR}..."
mkdir -p "${OUTPUT_DIR}"
chmod 700 "${OUTPUT_DIR}"

# Private key (PEM is already in $KEY_FILE; base64 is one-line)
cp "${KEY_FILE}" "${OUTPUT_DIR}/${NEW_USER}.key"
printf '%s\n' "${KEY_B64}" > "${OUTPUT_DIR}/${NEW_USER}.key.b64"
chmod 600 "${OUTPUT_DIR}/${NEW_USER}.key" "${OUTPUT_DIR}/${NEW_USER}.key.b64"

# Client cert (decode base64 from k8s CSR API to get PEM)
printf '%s' "${CRT_B64}" | base64 -d > "${OUTPUT_DIR}/${NEW_USER}.crt"
printf '%s\n' "${CRT_B64}" > "${OUTPUT_DIR}/${NEW_USER}.crt.b64"
chmod 644 "${OUTPUT_DIR}/${NEW_USER}.crt" "${OUTPUT_DIR}/${NEW_USER}.crt.b64"

# Cluster CA
printf '%s' "${CA_B64}" | base64 -d > "${OUTPUT_DIR}/ca.crt"
printf '%s\n' "${CA_B64}" > "${OUTPUT_DIR}/ca.crt.b64"
chmod 644 "${OUTPUT_DIR}/ca.crt" "${OUTPUT_DIR}/ca.crt.b64"

echo
echo "7) Verifying outputs..."
openssl x509 -in "${OUTPUT_DIR}/${NEW_USER}.crt" -noout -subject -issuer -dates
echo "    client cert chain verifies against CA:"
openssl verify -CAfile "${OUTPUT_DIR}/ca.crt" "${OUTPUT_DIR}/${NEW_USER}.crt"

echo
echo "✓ Done. Files written to ${OUTPUT_DIR}:"
ls -la "${OUTPUT_DIR}"
echo
echo "  Use them e.g. with:"
echo "    kubectl --server=${API_ENDPOINT} \\"
echo "            --certificate-authority=${OUTPUT_DIR}/ca.crt \\"
echo "            --client-certificate=${OUTPUT_DIR}/${NEW_USER}.crt \\"
echo "            --client-key=${OUTPUT_DIR}/${NEW_USER}.key \\"
echo "            get nodes"
