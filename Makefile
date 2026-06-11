# Entry points for the vast.kubernetes Ansible collection.
#
# Usage:
#   make install       # create .venv + install ansible/galaxy/pip deps (isolated)
#   make k8s           # bootstrap kubeadm cluster
#   make csi           # install VAST CSI driver
#   make zarf          # deploy VAST DataEngine
#   make user          # provision k8s users (drives playbooks/users.yml)
#   make site          # all of the above in dependency order
#   make check         # ansible-playbook --check --diff (dry-run)
#   make lint          # ansible-lint + yamllint + shellcheck
#   make test          # offline test battery (CI safe)
#   make vault-edit    # ansible-vault edit inventory/group_vars/all/vault.yml
#   make vault-rekey   # rotate vault password
#   make clean         # remove .retry, .cache, /tmp artifacts (keeps .venv)
#   make distclean     # also wipe .venv and the Galaxy collections cache

SHELL := /bin/bash
COLLECTION := vast.kubernetes
SITE := collections/ansible_collections/vast/kubernetes/playbooks/site.yml
INV := inventory/hosts.ini
TEST_INV := inventory/localhost.ini
VAULT := inventory/group_vars/all/vault.yml

# Use the project-local virtualenv if it exists; otherwise fall back to PATH.
# `make install` populates .venv/. After that, every other target uses it
# automatically — no sourcing required, no system Python pollution.
VENV := .venv
PYTHON3 ?= python3
PIP := $(VENV)/bin/pip
ANSIBLE_PLAYBOOK := $(if $(wildcard $(VENV)/bin/ansible-playbook),$(VENV)/bin/ansible-playbook,ansible-playbook)
ANSIBLE_GALAXY   := $(if $(wildcard $(VENV)/bin/ansible-galaxy),$(VENV)/bin/ansible-galaxy,ansible-galaxy)
ANSIBLE_LINT     := $(if $(wildcard $(VENV)/bin/ansible-lint),$(VENV)/bin/ansible-lint,ansible-lint)
ANSIBLE_VAULT    := $(if $(wildcard $(VENV)/bin/ansible-vault),$(VENV)/bin/ansible-vault,ansible-vault)
ANSIBLE_INV      := $(if $(wildcard $(VENV)/bin/ansible-inventory),$(VENV)/bin/ansible-inventory,ansible-inventory)
ANSIBLE_PING     := $(if $(wildcard $(VENV)/bin/ansible),$(VENV)/bin/ansible,ansible)
YAMLLINT         := $(if $(wildcard $(VENV)/bin/yamllint),$(VENV)/bin/yamllint,yamllint)

ANSIBLE := $(ANSIBLE_PLAYBOOK) -i $(INV)

.DEFAULT_GOAL := help

.PHONY: help install venv k8s csi zarf user site check lint test ping \
        vault-edit vault-rekey clean distclean

help:
	@awk '/^# / && NR<=20 {print substr($$0, 3)}' $(MAKEFILE_LIST)

# Create an isolated virtualenv and install Ansible + ansible-lint + the
# kubernetes Python lib into it. NOTHING goes to system Python.
$(VENV)/bin/activate:
	$(PYTHON3) -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --upgrade pip

venv: $(VENV)/bin/activate

install: venv
	$(PIP) install -r requirements.txt
	$(ANSIBLE_GALAXY) collection install -r requirements.yml -p ./collections
	@echo
	@echo "Done. Activate the venv with:  source $(VENV)/bin/activate"
	@echo "Or just use make targets — they auto-detect $(VENV)/."

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

ping:
	$(ANSIBLE_PING) all -m ping -i $(INV)

lint:
	$(ANSIBLE_LINT)
	$(YAMLLINT) .
	shellcheck user-setup/*.sh

# Offline test battery — no SSH, no live cluster. Runs in CI safely.
test:
	@echo "==> ansible-playbook --syntax-check (5 playbooks)"
	@for p in site k8s_cluster csi zarf users; do \
		$(ANSIBLE_PLAYBOOK) collections/ansible_collections/vast/kubernetes/playbooks/$$p.yml --syntax-check >/dev/null \
		  && echo "    $$p.yml: OK" || exit 1; \
	done
	@echo "==> ansible-inventory --list (parse hosts.ini)"
	@$(ANSIBLE_INV) --list >/dev/null && echo "    hosts.ini: OK"
	@$(ANSIBLE_INV) --list -i $(TEST_INV) >/dev/null && echo "    localhost.ini: OK"
	@echo "==> ansible-playbook --list-tasks (resolve roles + tags + vars)"
	@for p in k8s_cluster csi zarf users; do \
		$(ANSIBLE_PLAYBOOK) -i $(TEST_INV) collections/ansible_collections/vast/kubernetes/playbooks/$$p.yml --list-tasks >/dev/null \
		  && echo "    $$p.yml: OK" || exit 1; \
	done
	@echo "==> yamllint"
	@$(YAMLLINT) . && echo "    yamllint: OK"
	@echo "==> ansible-lint (production profile)"
	@$(ANSIBLE_LINT) $(SITE) 2>&1 | tail -1
	@echo "==> shellcheck"
	@shellcheck user-setup/*.sh && echo "    shellcheck: OK"
	@echo "==> bash -n"
	@bash -n user-setup/*.sh && echo "    bash -n: OK"

vault-edit:
	$(ANSIBLE_VAULT) edit $(VAULT)

vault-rekey:
	$(ANSIBLE_VAULT) rekey $(VAULT)

clean:
	find . -name '*.retry' -delete
	rm -rf .cache /tmp/vast-csi-values.rendered.yaml /tmp/knative-op.yaml /tmp/knative-crds.yaml

distclean: clean
	rm -rf $(VENV)
	rm -rf collections/ansible_collections/community \
	       collections/ansible_collections/kubernetes \
	       collections/ansible_collections/ansible \
	       collections/ansible_collections/*.info
