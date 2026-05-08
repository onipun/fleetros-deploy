# fleetros-deploy — top-level orchestrator
# All commands assume you run them from the repo root.

SHELL := /bin/bash
.DEFAULT_GOAL := help

VM_NAME       ?= fleetros-local
VM_CPUS       ?= 4
VM_MEMORY     ?= 8G
VM_DISK       ?= 40G
VM_IMAGE      ?= 24.04

ANSIBLE_DIR   := infra/ansible
LOCAL_INV     := $(ANSIBLE_DIR)/inventory/local.yml
PROD_INV      := $(ANSIBLE_DIR)/inventory/prod.yml
VAULT_LOCAL   := --vault-password-file .vault-pass.local
VAULT_PROD    := --vault-password-file .vault-pass

KUBECONFIG_LOCAL := $(HOME)/.kube/fleetros-local
KUBECONFIG_PROD  := $(HOME)/.kube/fleetros-prod

GITOPS_DIR    := gitops
LOCAL_VALUES  := $(GITOPS_DIR)/environments/local/values.yaml
PROD_VALUES   := $(GITOPS_DIR)/environments/prod/values.yaml

##@ Help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n\n"} \
		/^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Local (Phase 0)
local-up: local-vm-up local-configure ## Provision multipass VM + run Ansible bootstrap
	@echo "Local cluster ready. Run: make local-deploy"

local-vm-up: ## Launch multipass VM (idempotent)
	@if multipass info $(VM_NAME) >/dev/null 2>&1; then \
		echo "VM $(VM_NAME) already exists"; \
	else \
		multipass launch --name $(VM_NAME) --cpus $(VM_CPUS) --memory $(VM_MEMORY) --disk $(VM_DISK) $(VM_IMAGE); \
	fi
	@multipass info $(VM_NAME) | grep -E 'IPv4'
	@$(MAKE) --no-print-directory local-vm-ssh-trust

local-vm-ssh-trust: ## Inject host SSH pubkey into VM's ubuntu user (idempotent)
	@PUBKEY_FILE=$$( [ -f $(HOME)/.ssh/id_ed25519.pub ] && echo $(HOME)/.ssh/id_ed25519.pub || echo $(HOME)/.ssh/id_rsa.pub ); \
	if [ ! -f "$$PUBKEY_FILE" ]; then \
		echo "ERROR: no SSH pubkey at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub. Generate with: ssh-keygen -t ed25519"; exit 1; \
	fi; \
	PUB=$$(cat $$PUBKEY_FILE); \
	multipass exec $(VM_NAME) -- bash -c "install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh && touch /home/ubuntu/.ssh/authorized_keys && chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys && chmod 600 /home/ubuntu/.ssh/authorized_keys && grep -qxF '$$PUB' /home/ubuntu/.ssh/authorized_keys || echo '$$PUB' >> /home/ubuntu/.ssh/authorized_keys"
	@VM_IP=$$(multipass info $(VM_NAME) | awk '/IPv4/ {print $$2; exit}'); \
	ssh-keygen -R $$VM_IP >/dev/null 2>&1 || true; \
	echo "SSH trust seeded for ubuntu@$$VM_IP"

local-configure: ## Run Ansible site.yml against local VM
	@test -f $(ANSIBLE_DIR)/.vault-pass.local || (echo "ERROR: $(ANSIBLE_DIR)/.vault-pass.local missing. Run: echo localdummypass > $(ANSIBLE_DIR)/.vault-pass.local" && exit 1)
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml >/dev/null
	cd $(ANSIBLE_DIR) && ansible-playbook -i ../../$(LOCAL_INV) site.yml $(VAULT_LOCAL)

local-kubeconfig: ## Fetch kubeconfig from local VM to ~/.kube/fleetros-local
	@mkdir -p $(HOME)/.kube
	multipass exec $(VM_NAME) -- sudo cat /etc/rancher/k3s/k3s.yaml | \
		sed "s/127.0.0.1/$$(multipass info $(VM_NAME) | awk '/IPv4/ {print $$2; exit}')/" \
		> $(KUBECONFIG_LOCAL)
	@echo "export KUBECONFIG=$(KUBECONFIG_LOCAL)"

local-deploy: ## Apply Argo CD root app for local environment
	KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl apply -f $(GITOPS_DIR)/bootstrap/root-app-local.yaml

local-test: ## Run 7-point validation suite
	@bash scripts/local-test.sh

local-argocd-ui: ## Print Argo CD UI URL + admin password (NodePort)
	@VM_IP=$$(multipass info $(VM_NAME) | awk '/IPv4/ {print $$2; exit}'); \
	PORT=$$(KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n argocd get svc argocd-server \
		-o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'); \
	PW=$$(KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d); \
	echo "Argo CD UI: http://$$VM_IP:$$PORT"; \
	echo "Username:   admin"; \
	echo "Password:   $$PW"

local-argocd-portforward: ## Port-forward Argo CD UI to https://localhost:8443 (Ctrl+C to stop)
	KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n argocd port-forward svc/argocd-server 8443:443

local-k9s: ## Open k9s on the local VM (TUI cluster debugger)
	multipass exec $(VM_NAME) -- k9s

local-reset: local-down local-up ## Wipe and recreate local VM

local-down: ## Destroy local VM
	-multipass delete --purge $(VM_NAME)

##@ Local — k3d (fast inner loop on Podman)
local-k3d-up: ## Spin up k3d cluster on Podman (no Ansible)
	DOCKER_HOST=unix://$$XDG_RUNTIME_DIR/podman/podman.sock \
		k3d cluster create fleetros-k3d --servers 1 \
		-p "80:80@loadbalancer" -p "443:443@loadbalancer"

local-k3d-down:
	-DOCKER_HOST=unix://$$XDG_RUNTIME_DIR/podman/podman.sock k3d cluster delete fleetros-k3d

##@ Prod (Phase 1+)
prod-configure: ## Run Ansible site.yml against the production VPS
	@test -f .vault-pass || (echo "ERROR: .vault-pass missing. Restore from your password manager." && exit 1)
	@test -f $(PROD_INV) || (echo "ERROR: $(PROD_INV) missing. Generate with: make tofu-inventory" && exit 1)
	cd $(ANSIBLE_DIR) && ansible-playbook -i ../../$(PROD_INV) site.yml $(VAULT_PROD)

prod-deploy: ## Apply Argo CD root app for prod environment
	KUBECONFIG=$(KUBECONFIG_PROD) kubectl apply -f $(GITOPS_DIR)/bootstrap/root-app-prod.yaml

prod-up: tofu-apply tofu-inventory prod-configure ## Provision VPS + Ansible bootstrap

tofu-init:
	cd infra/tofu && tofu init

tofu-plan:
	cd infra/tofu && tofu plan

tofu-apply:
	cd infra/tofu && tofu apply

tofu-destroy:
	cd infra/tofu && tofu destroy

tofu-inventory: ## Generate Ansible prod inventory from tofu outputs
	cd infra/tofu && tofu output -json > /tmp/tofu-out.json
	bash scripts/render-prod-inventory.sh /tmp/tofu-out.json $(PROD_INV)

##@ Secrets
secrets-edit-local: ## Edit local dummy vault (gitignored)
	$(EDITOR) $(ANSIBLE_DIR)/group_vars/local/vault.yml

secrets-edit-prod: ## Edit production vault (encrypted)
	cd $(ANSIBLE_DIR) && ansible-vault edit group_vars/all/vault.yml $(VAULT_PROD)

##@ Helm
helm-lint: ## Lint umbrella chart
	helm lint $(GITOPS_DIR)/charts/fleetros -f $(LOCAL_VALUES)
	helm lint $(GITOPS_DIR)/charts/fleetros -f $(PROD_VALUES)

helm-template-local: ## Render local manifests for inspection
	helm template fleetros $(GITOPS_DIR)/charts/fleetros -f $(LOCAL_VALUES)

helm-template-prod:
	helm template fleetros $(GITOPS_DIR)/charts/fleetros -f $(PROD_VALUES)

.PHONY: help local-up local-vm-up local-configure local-kubeconfig local-deploy local-test \
        local-reset local-down local-k3d-up local-k3d-down prod-configure prod-deploy prod-up \
        tofu-init tofu-plan tofu-apply tofu-destroy tofu-inventory secrets-edit-local \
        secrets-edit-prod helm-lint helm-template-local helm-template-prod \
        local-argocd-ui local-argocd-portforward local-k9s local-vm-ssh-trust
