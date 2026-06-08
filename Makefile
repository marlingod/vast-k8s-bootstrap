# Entry points for the vast.kubernetes Ansible collection.
#
# Usage:
#   make install       # ansible-galaxy + pip deps
#   make k8s           # bootstrap kubeadm cluster
#   make csi           # install VAST CSI driver
#   make zarf          # deploy VAST DataEngine
#   make user          # provision k8s users (drives playbooks/users.yml)
#   make site          # all of the above in dependency order
#   make check         # ansible-playbook --check --diff (dry-run)
#   make lint          # ansible-lint + yamllint + shellcheck
#   make vault-edit    # ansible-vault edit inventory/group_vars/all/vault.yml
#   make vault-rekey   # rotate vault password
#   make clean         # remove .retry, .cache, /tmp artifacts

SHELL := /bin/bash
COLLECTION := vast.kubernetes
SITE := collections/ansible_collections/vast/kubernetes/playbooks/site.yml
INV := inventory/hosts.ini
TEST_INV := inventory/localhost.ini
VAULT := inventory/group_vars/all/vault.yml
ANSIBLE := ansible-playbook -i $(INV)

.DEFAULT_GOAL := help

.PHONY: help install k8s csi zarf user site check lint test vault-edit vault-rekey clean

help:
	@awk '/^# / && NR<=25 {print substr($$0, 3)}' $(MAKEFILE_LIST)

install:
	ansible-galaxy collection install -r requirements.yml -p ./collections
	pip install -r requirements.txt

k8s:
	$(ANSIBLE) $(SITE) --tags k8s

csi:
	$(ANSIBLE) $(SITE) --tags csi

zarf:
	$(ANSIBLE) $(SITE) --tags zarf

user:
	$(ANSIBLE) $(SITE) --tags users

site:
	$(ANSIBLE) $(SITE)

check:
	$(ANSIBLE) $(SITE) --check --diff

lint:
	ansible-lint
	yamllint .
	shellcheck user-setup/*.sh

# Offline test battery — no SSH, no live cluster. Runs in CI safely.
test:
	@echo "==> ansible-playbook --syntax-check (5 playbooks)"
	@for p in site k8s_cluster csi zarf users; do \
		ansible-playbook collections/ansible_collections/vast/kubernetes/playbooks/$$p.yml --syntax-check >/dev/null \
		  && echo "    $$p.yml: OK" || exit 1; \
	done
	@echo "==> ansible-inventory --list (parse hosts.ini)"
	@ansible-inventory --list >/dev/null && echo "    hosts.ini: OK"
	@ansible-inventory --list -i $(TEST_INV) >/dev/null && echo "    localhost.ini: OK"
	@echo "==> ansible-playbook --list-tasks (resolve roles + tags + vars)"
	@for p in k8s_cluster csi zarf users; do \
		ansible-playbook -i $(TEST_INV) collections/ansible_collections/vast/kubernetes/playbooks/$$p.yml --list-tasks >/dev/null \
		  && echo "    $$p.yml: OK" || exit 1; \
	done
	@echo "==> yamllint"
	@yamllint . && echo "    yamllint: OK"
	@echo "==> ansible-lint (production profile)"
	@ansible-lint $(SITE) 2>&1 | tail -1
	@echo "==> shellcheck"
	@shellcheck user-setup/*.sh && echo "    shellcheck: OK"
	@echo "==> bash -n"
	@bash -n user-setup/*.sh && echo "    bash -n: OK"

vault-edit:
	ansible-vault edit $(VAULT)

vault-rekey:
	ansible-vault rekey $(VAULT)

clean:
	find . -name '*.retry' -delete
	rm -rf .cache /tmp/vast-csi-values.rendered.yaml /tmp/knative-op.yaml /tmp/knative-crds.yaml
