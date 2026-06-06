# vast.kubernetes Ansible Collection

Reusable roles and playbooks for VAST's Kubernetes stack:

1. `k8s_cluster.yml` — bootstrap a kubeadm cluster (containerd + Flannel CNI).
2. `csi.yml` — install the VAST CSI driver via Helm.
3. `zarf.yml` — deploy the VAST DataEngine via Zarf (air-gapped capable).
4. `users.yml` — provision K8s users (RBAC + X.509 client certs).

See the top-level `README.md` for end-to-end usage. This collection sits at
`collections/ansible_collections/vast/kubernetes/` so it is auto-resolved by
the project `ansible.cfg`.
