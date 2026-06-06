#!/usr/bin/env bash
set -euo pipefail
umask 077

# SSH-driven X.509 cert issuance — merged successor of create-user-cert-remote.sh
# AND dump-user-certs-remote.sh. Emits a kubeconfig, raw PEM files, or both.
#
# Flags:
#   --user NAME          K8s user (CN of the cert)        [required]
#   --host HOST          master IP/hostname               [required]
#   --ssh-user USER      SSH login on master              [default: vastdata]
#   --group GROUP        cert O= field                    [default: ""]
#   --role ROLE          ClusterRole to bind              [default: cluster-admin]
#   --endpoint URL       apiserver URL                    [default: https://HOST:6443]
#   --days N             cert validity                    [default: 365]
#   --cluster NAME       kubeconfig "cluster" name        [default: vastde-cluster]
#   --format FMT         kubeconfig | pem | both          [default: kubeconfig]
#   --output PATH        kubeconfig path / cert dir
#
# Auth: key-based SSH is required (no plaintext password support). To override
# temporarily, export SSHPASS and the script will use `sshpass -e ssh`.

NEW_USER=""
USER_GROUP=""
ROLE="cluster-admin"
SSH_USER="vastdata"
SSH_HOST=""
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
REMOTE_KUBECONFIG="/etc/kubernetes/admin.conf"
API_ENDPOINT=""
OUTPUT=""
CLUSTER_NAME="vastde-cluster"
CERT_DAYS=365
FORMAT="kubeconfig"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)     NEW_USER="$2"; shift 2 ;;
    --host)     SSH_HOST="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --group)    USER_GROUP="$2"; shift 2 ;;
    --role)     ROLE="$2"; shift 2 ;;
    --endpoint) API_ENDPOINT="$2"; shift 2 ;;
    --days)     CERT_DAYS="$2"; shift 2 ;;
    --cluster)  CLUSTER_NAME="$2"; shift 2 ;;
    --format)   FORMAT="$2"; shift 2 ;;
    --output)   OUTPUT="$2"; shift 2 ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \?//' >&2
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "${NEW_USER}" ] || { echo "ERROR: --user required" >&2; exit 2; }
[ -n "${SSH_HOST}" ] || { echo "ERROR: --host required" >&2; exit 2; }
case "${FORMAT}" in
  kubeconfig|pem|both) ;;
  *) echo "ERROR: --format must be kubeconfig|pem|both" >&2; exit 2 ;;
esac

API_ENDPOINT="${API_ENDPOINT:-https://${SSH_HOST}:6443}"

command -v openssl >/dev/null || { echo "ERROR: openssl required" >&2; exit 1; }
command -v ssh     >/dev/null || { echo "ERROR: ssh required"     >&2; exit 1; }

SSH_TARGET="${SSH_USER}@${SSH_HOST}"
if [ -n "${SSHPASS:-}" ]; then
  command -v sshpass >/dev/null || { echo "ERROR: SSHPASS set but sshpass not installed" >&2; exit 1; }
  SSH_CMD=(sshpass -e ssh)
else
  SSH_CMD=(ssh)
fi

# Sudo invocation: root needs nothing; non-root assumes NOPASSWD sudo or
# a SUDOPASS env var (no fallback to SSH password — keep them separate).
if [ "${SSH_USER}" = "root" ]; then
  REMOTE_INVOKE='bash -s'
  SUDO_STDIN_PREFIX=""
elif [ -n "${SUDOPASS:-}" ]; then
  REMOTE_INVOKE="sudo -S -p '' bash -s"
  SUDO_STDIN_PREFIX="${SUDOPASS}"$'\n'
else
  REMOTE_INVOKE='sudo -n bash -s'
  SUDO_STDIN_PREFIX=""
fi

WORKDIR="$(mktemp -d)"; trap 'rm -rf "${WORKDIR}"' EXIT
KEY_FILE="${WORKDIR}/${NEW_USER}.key"
CSR_FILE="${WORKDIR}/${NEW_USER}.csr"
REMOTE_OUT="${WORKDIR}/remote.out"
CSR_NAME="${NEW_USER}-csr"
EXPIRATION_SECONDS=$(( CERT_DAYS * 24 * 3600 ))

echo "1) Probing SSH to ${SSH_TARGET}..."
"${SSH_CMD[@]}" "${SSH_OPTS[@]}" "${SSH_TARGET}" 'true' \
  || { echo "ERROR: cannot SSH to ${SSH_TARGET}" >&2; exit 1; }

echo "2) Generating private key + CSR locally (CN=${NEW_USER}${USER_GROUP:+, O=${USER_GROUP}})..."
openssl genrsa -out "${KEY_FILE}" 2048 2>/dev/null
SUBJ="/CN=${NEW_USER}"
[ -n "${USER_GROUP}" ] && SUBJ="${SUBJ}/O=${USER_GROUP}"
openssl req -new -key "${KEY_FILE}" -out "${CSR_FILE}" -subj "${SUBJ}"
CSR_B64=$(base64 < "${CSR_FILE}" | tr -d '\n')

echo "3) Submitting CSR + ClusterRoleBinding on ${SSH_TARGET}..."
{
  [ -n "${SUDO_STDIN_PREFIX}" ] && printf '%s' "${SUDO_STDIN_PREFIX}"
  cat <<REMOTE
set -euo pipefail
export KUBECONFIG="${REMOTE_KUBECONFIG}"

kubectl delete csr "${CSR_NAME}" --ignore-not-found >/dev/null

kubectl apply -f - >/dev/null <<CSR_END
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

kubectl certificate approve "${CSR_NAME}" >/dev/null

CRT_B64=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  CRT_B64=\$(kubectl get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}' 2>/dev/null || true)
  [ -n "\${CRT_B64}" ] && break
  sleep 1
done
[ -n "\${CRT_B64}" ] || { echo "REMOTE-ERROR: cert not issued" >&2; exit 1; }

kubectl apply -f - >/dev/null <<RBAC_END
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
} | "${SSH_CMD[@]}" "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_INVOKE}" >"${REMOTE_OUT}"

echo "4) Parsing remote output..."
awk '/^---SIGNED-CERT-B64---$/{flag="crt"; next}
     /^---CA-CERT-B64---$/{flag="ca"; next}
     /^---END---$/{flag=""; next}
     flag=="crt"{print > "'"${WORKDIR}/crt.b64"'"}
     flag=="ca" {print > "'"${WORKDIR}/ca.b64"'"}' "${REMOTE_OUT}"

CRT_B64=$(tr -d '\n' < "${WORKDIR}/crt.b64" 2>/dev/null || true)
CA_B64=$(tr -d '\n' < "${WORKDIR}/ca.b64" 2>/dev/null || true)
[ -n "${CRT_B64}" ] || { echo "ERROR: no signed cert"; cat "${REMOTE_OUT}"; exit 1; }
[ -n "${CA_B64}" ]  || { echo "ERROR: no CA cert";   cat "${REMOTE_OUT}"; exit 1; }
KEY_B64=$(base64 < "${KEY_FILE}" | tr -d '\n')

OUT_KUBECONFIG="${OUTPUT:-$HOME/.kube/${NEW_USER}-cert.yaml}"
OUT_CERT_DIR="${OUTPUT:-$HOME/.kube/${NEW_USER}-certs}"

if [ "${FORMAT}" = "kubeconfig" ] || [ "${FORMAT}" = "both" ]; then
  echo "5a) Writing kubeconfig to ${OUT_KUBECONFIG}..."
  mkdir -p "$(dirname "${OUT_KUBECONFIG}")"
  cat > "${OUT_KUBECONFIG}" <<KUBECFG_END
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
  chmod 600 "${OUT_KUBECONFIG}"
fi

if [ "${FORMAT}" = "pem" ] || [ "${FORMAT}" = "both" ]; then
  echo "5b) Writing PEM + base64 files to ${OUT_CERT_DIR}..."
  mkdir -p "${OUT_CERT_DIR}"; chmod 700 "${OUT_CERT_DIR}"
  cp "${KEY_FILE}" "${OUT_CERT_DIR}/${NEW_USER}.key"
  printf '%s\n' "${KEY_B64}" > "${OUT_CERT_DIR}/${NEW_USER}.key.b64"
  printf '%s' "${CRT_B64}" | base64 -d > "${OUT_CERT_DIR}/${NEW_USER}.crt"
  printf '%s\n' "${CRT_B64}" > "${OUT_CERT_DIR}/${NEW_USER}.crt.b64"
  printf '%s' "${CA_B64}" | base64 -d > "${OUT_CERT_DIR}/ca.crt"
  printf '%s\n' "${CA_B64}" > "${OUT_CERT_DIR}/ca.crt.b64"
  chmod 600 "${OUT_CERT_DIR}/${NEW_USER}.key" "${OUT_CERT_DIR}/${NEW_USER}.key.b64"
  chmod 600 "${OUT_CERT_DIR}/${NEW_USER}.crt" "${OUT_CERT_DIR}/${NEW_USER}.crt.b64"
  chmod 600 "${OUT_CERT_DIR}/ca.crt" "${OUT_CERT_DIR}/ca.crt.b64"
  echo "   Verifying cert chain..."
  openssl verify -CAfile "${OUT_CERT_DIR}/ca.crt" "${OUT_CERT_DIR}/${NEW_USER}.crt"
fi

if [ "${FORMAT}" = "kubeconfig" ] || [ "${FORMAT}" = "both" ]; then
  echo "6) Test:"
  KUBECONFIG="${OUT_KUBECONFIG}" kubectl auth whoami
  KUBECONFIG="${OUT_KUBECONFIG}" kubectl get nodes
fi

echo
echo "Done. Cert valid ~${CERT_DAYS} days. Re-run to rotate."
