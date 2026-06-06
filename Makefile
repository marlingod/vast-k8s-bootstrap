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
VAULT := inventory/group_vars/all/vault.yml
ANSIBLE := ansible-playbook -i $(INV)

.DEFAULT_GOAL := help

.PHONY: help install k8s csi zarf user site check lint vault-edit vault-rekey clean

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

vault-edit:
	ansible-vault edit $(VAULT)

vault-rekey:
	ansible-vault rekey $(VAULT)

clean:
	find . -name '*.retry' -delete
	rm -rf .cache /tmp/vast-csi-values.rendered.yaml /tmp/knative-op.yaml /tmp/knative-crds.yaml
