#!/usr/bin/env bash
set -euo pipefail

# ─── EDIT THESE ────────────────────────────────────────────────────────────
NEW_USER="ca-admin"
USER_GROUP=""                              # optional, becomes O= in cert (e.g. "system:masters")
ROLE="cluster-admin"

SSH_USER="vastdata"                        # SSH login on the master node
SSH_HOST="10.143.2.26"                     # master IP of the target K8s cluster
SSH_PASSWORD="vastdata"                    # leave empty to use key auth (recommended).
                                           # If set, requires `sshpass` (brew install hudochenkov/sshpass/sshpass).
                                           # ⚠ Storing a password in plaintext is risky — prefer SSH keys.
SUDO_PASSWORD=""                           # leave empty to reuse SSH_PASSWORD. Set to "" + SSH_USER=root,
                                           # or configure NOPASSWD sudo on the remote, to skip sudo prompt entirely.
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
REMOTE_KUBECONFIG="/etc/kubernetes/admin.conf"

# Derive the apiserver URL from SSH_HOST by default (override if the apiserver
# is on a different host than SSH, e.g. an LB).
API_ENDPOINT="https://${SSH_HOST}:6443"

OUTPUT_KUBECONFIG="$HOME/.kube/${NEW_USER}-cert.yaml"
# Local folder where the 3 PEM files (ca.pem, client.pem, client.key) get
# written for downstream tools (e.g. `vastde-orch enable`'s VMS↔K8s mTLS step).
CERT_DIR="$HOME/.kube/${NEW_USER}-certs"
CLUSTER_NAME="ca-tenant-k8s"
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
command -v kubectl >/dev/null  || { echo "ERROR: kubectl is required";  exit 1; }
command -v ssh     >/dev/null  || { echo "ERROR: ssh is required";      exit 1; }

SSH_TARGET="${SSH_USER}@${SSH_HOST}"
if [ -n "${SSH_PASSWORD}" ]; then
  command -v sshpass >/dev/null || {
    echo "ERROR: SSH_PASSWORD is set but 'sshpass' is not installed."
    echo "       Install it (macOS: brew install hudochenkov/sshpass/sshpass) or clear SSH_PASSWORD to use key auth."
    exit 1
  }
  # SSHPASS env avoids leaking the password into process listings.
  export SSHPASS="${SSH_PASSWORD}"
  SSH_CMD=(sshpass -e ssh)
else
  SSH_CMD=(ssh)
fi

# Pick how the remote invokes bash: root → direct, non-root → sudo (-S if we have a password, else -n).
: "${SUDO_PASSWORD:=${SSH_PASSWORD}}"
if [ "${SSH_USER}" = "root" ]; then
  REMOTE_INVOKE='bash -s'
  SUDO_STDIN_PREFIX=""
elif [ -n "${SUDO_PASSWORD}" ]; then
  # sudo -S reads the password from stdin (terminated by newline); bash -s then reads the rest as its script.
  # -p '' suppresses the prompt so nothing leaks onto stderr/stdout.
  REMOTE_INVOKE="sudo -S -p '' bash -s"
  SUDO_STDIN_PREFIX="${SUDO_PASSWORD}"$'\n'
else
  REMOTE_INVOKE='sudo -n bash -s'
  SUDO_STDIN_PREFIX=""
fi

echo "1) Probing apiserver ${API_ENDPOINT}/healthz..."
if ! curl --max-time 5 -sk -o /dev/null -w '%{http_code}\n' "${API_ENDPOINT}/healthz" | grep -q '^200$'; then
  echo "   WARNING: ${API_ENDPOINT}/healthz did not return 200 from this host."
  echo "            Continuing — the SSH user-creation will still proceed; the local"
  echo "            connectivity test at the end may fail if this machine cannot"
  echo "            reach the apiserver."
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
# The heredoc is UNQUOTED so local $VARS interpolate into the payload before being
# sent over SSH. When sudo needs a password we prepend it to stdin; sudo -S consumes
# the first line and hands the remaining stdin to bash -s.
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

# Drop any stale CSR with the same name (CSRs are cluster-scoped and immutable after approval).
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

# CA cert: prefer the one embedded in admin.conf; fall back to the PKI dir.
CA_B64=\$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
if [ -z "\${CA_B64}" ]; then
  CA_PATH=\$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')
  [ -z "\${CA_PATH}" ] && CA_PATH=/etc/kubernetes/pki/ca.crt
  CA_B64=\$(base64 < "\${CA_PATH}" | tr -d '\n')
fi

# Emit a parseable result block on stdout.
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

echo "6) Writing kubeconfig to ${OUTPUT_KUBECONFIG}..."
mkdir -p "$(dirname "${OUTPUT_KUBECONFIG}")"
cat > "${OUTPUT_KUBECONFIG}" <<KUBECFG_END
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
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
      cluster: ${CLUSTER_NAME}
      user: ${NEW_USER}
      namespace: default
current-context: ${NEW_USER}-ctx
KUBECFG_END
chmod 600 "${OUTPUT_KUBECONFIG}"

echo "7) Writing PEM files to ${CERT_DIR}..."
mkdir -p "${CERT_DIR}"
# Decode base64 → raw PEM. Use `base64 -d` (GNU/macOS) — `-D` is macOS-only.
printf '%s' "${CA_B64}"  | base64 -d > "${CERT_DIR}/ca.pem"
printf '%s' "${CRT_B64}" | base64 -d > "${CERT_DIR}/client.pem"
cp "${KEY_FILE}"                       "${CERT_DIR}/client.key"
chmod 600 "${CERT_DIR}/client.key"
chmod 644 "${CERT_DIR}/ca.pem" "${CERT_DIR}/client.pem"

echo
echo "8) Testing the new kubeconfig from this machine..."
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl auth whoami
KUBECONFIG="${OUTPUT_KUBECONFIG}" kubectl get nodes

echo
echo "✓ Done."
echo "  Kubeconfig:  ${OUTPUT_KUBECONFIG}"
echo "  PEM files:   ${CERT_DIR}/{ca.pem,client.pem,client.key}"
echo "  Use:         export KUBECONFIG=${OUTPUT_KUBECONFIG}"
echo "  Cert valid for ~${CERT_DAYS} days. Re-run this script to rotate."
