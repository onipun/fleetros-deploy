# fleetros-deploy — top-level orchestrator
# All commands assume you run them from the repo root.

SHELL := /bin/bash
.DEFAULT_GOAL := help

VM_NAME       ?= fleetros-local
VM_CPUS       ?= 4
VM_MEMORY     ?= 12G
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
local-up: local-mkcert-check local-vm-up local-configure ## Provision multipass VM + run Ansible bootstrap
	@echo "Local cluster ready. Run: make local-deploy"

local-mkcert-check: ## Verify mkcert is installed on host and the local CA is trusted
	@command -v mkcert >/dev/null || { \
		echo "ERROR: mkcert not installed. Install it then run 'mkcert -install'."; \
		echo "  Linux:  sudo apt install libnss3-tools && wget -qO- https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64 | sudo tee /usr/local/bin/mkcert >/dev/null && sudo chmod +x /usr/local/bin/mkcert"; \
		echo "  macOS:  brew install mkcert nss"; \
		exit 1; \
	}
	@CAROOT=$$(mkcert -CAROOT); \
	if [ ! -f "$$CAROOT/rootCA.pem" ] || [ ! -f "$$CAROOT/rootCA-key.pem" ]; then \
		echo "ERROR: mkcert CA not generated. Run: mkcert -install"; exit 1; \
	fi; \
	echo "mkcert CAROOT: $$CAROOT (rootCA present)"

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

local-traefik-portforward: ## Port-forward Traefik dashboard to http://localhost:9000/dashboard/ (Ctrl+C to stop)
	KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n kube-system port-forward svc/traefik 9000:9000

local-stackgres-ui: ## Print the StackGres Web UI URL + admin credentials
	@VM_IP=$$(multipass info $(VM_NAME) | awk '/IPv4/ {print $$2; exit}'); \
	USER=$$(KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n stackgres get secret stackgres-restapi-admin \
		-o jsonpath='{.data.k8sUsername}' 2>/dev/null | base64 -d); \
	PW=$$(KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n stackgres get secret stackgres-restapi-admin \
		-o jsonpath='{.data.clearPassword}' 2>/dev/null | base64 -d); \
	echo "StackGres UI: https://stackgres.fleetros.local"; \
	echo "  (or via VM IP: https://$$VM_IP — Host header: stackgres.fleetros.local)"; \
	echo "Username:     $$USER"; \
	echo "Password:     $$PW"

local-stackgres-portforward: ## Port-forward StackGres UI to https://localhost:8843
	KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n stackgres port-forward svc/stackgres-restapi 8843:443

local-k9s: ## Open k9s on the local VM (TUI cluster debugger)
	multipass exec $(VM_NAME) -- k9s

##@ Local — image builds
WEB_REPO_DIR ?= $(abspath ../fleetros-backoffice-v2)
WEB_IMAGE    ?= so0n/car-rental-backoffice-dashboard
WEB_TAG      ?= latest

local-build-web: ## Build fleetros-web image with local NEXT_PUBLIC_* baked in, import into k3s
	@test -d "$(WEB_REPO_DIR)" || { echo "ERROR: WEB_REPO_DIR=$(WEB_REPO_DIR) not found. Override with: make local-build-web WEB_REPO_DIR=/path/to/fleetros-backoffice-v2"; exit 1; }
	@echo "Building $(WEB_IMAGE):$(WEB_TAG) from $(WEB_REPO_DIR)"
	docker build \
		--build-arg NEXT_PUBLIC_APP_URL=https://app.fleetros.local \
		--build-arg NEXT_PUBLIC_PRIMARY_HOSTS=app.fleetros.local \
		--build-arg NEXT_PUBLIC_BRAND_NAME=Fleetros \
		--build-arg NEXT_PUBLIC_I18N_DEFAULT_LOCALE=en \
		--build-arg NEXT_PUBLIC_API_BASE_URL=https://api.fleetros.local \
		--build-arg NEXT_PUBLIC_API_URL=https://api.fleetros.local \
		--build-arg NEXT_PUBLIC_REPORTING_API_URL=https://reporting.fleetros.local \
		--build-arg NEXT_PUBLIC_SITE_EDITOR_URL=https://portal.fleetros.local \
		--build-arg NEXT_PUBLIC_PORTAL_API_BASE_URL=https://customer-api.fleetros.local \
		--build-arg NEXT_PUBLIC_ENABLE_ONBOARDING=true \
		--build-arg NEXT_PUBLIC_ENABLE_NOTIFICATIONS=true \
		--build-arg NEXT_PUBLIC_ENABLE_COMMAND_PALETTE=true \
		-t $(WEB_IMAGE):$(WEB_TAG) \
		"$(WEB_REPO_DIR)" && \
		docker push $(WEB_IMAGE):$(WEB_TAG)

	
	@$(MAKE) --no-print-directory local-import-web
	@$(MAKE) --no-print-directory local-rollout-web

local-import-web: ## Save fleetros-web image and import it into k3s containerd inside the VM
	@TMP=$$(mktemp -d "$$HOME/fleetros-web-XXXXXX"); TAR=$$TMP/web.tar; \
	echo "Saving $(WEB_IMAGE):$(WEB_TAG) -> $$TAR"; \
	docker save -o $$TAR $(WEB_IMAGE):$(WEB_TAG); \
	echo "Transferring to $(VM_NAME)"; \
	multipass transfer $$TAR $(VM_NAME):/tmp/fleetros-web.tar; \
	echo "Importing into k3s containerd (k8s.io namespace)"; \
	multipass exec $(VM_NAME) -- sudo /usr/local/bin/k3s ctr -n k8s.io images import /tmp/fleetros-web.tar; \
	multipass exec $(VM_NAME) -- sudo rm -f /tmp/fleetros-web.tar; \
	rm -rf $$TMP

local-rollout-web: ## Restart fleetros-web pods to pick up the freshly imported image
	@if KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app get deploy fleetros-web >/dev/null 2>&1; then \
		KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app rollout restart deploy/fleetros-web && \
		KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app rollout status  deploy/fleetros-web --timeout=180s; \
	else \
		echo "WARN: deploy/fleetros-web not found in namespace app. Sync Argo CD (commit + push gitops, then 'argocd app sync fleetros-local' or wait for auto-sync) and retry."; \
	fi

local-logs-web: ## Tail fleetros-web logs
	KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app logs -f deploy/fleetros-web --max-log-requests=10

# ── Customer portal (fleetros-website-builder) ────────────────────
CUSTOMER_REPO_DIR ?= $(abspath ../fleetros-website-builder)
CUSTOMER_IMAGE    ?= so0n/fleetros-website-builder
CUSTOMER_TAG      ?= latest

local-build-customer: ## Build fleetros-customer image with local NEXT_PUBLIC_* baked in, import into k3s
	@test -d "$(CUSTOMER_REPO_DIR)" || { echo "ERROR: CUSTOMER_REPO_DIR=$(CUSTOMER_REPO_DIR) not found. Override with: make local-build-customer CUSTOMER_REPO_DIR=/path/to/fleetros-website-builder"; exit 1; }
	@echo "Building $(CUSTOMER_IMAGE):$(CUSTOMER_TAG) from $(CUSTOMER_REPO_DIR)"
	docker build \
		--build-arg NEXT_PUBLIC_BASE_DOMAIN=portal.fleetros.local \
		--build-arg NEXT_PUBLIC_AUTH_HOST=https://app.fleetros.local \
		--build-arg NEXT_PUBLIC_AUTH_PORT=443 \
		--build-arg NEXT_PUBLIC_RENTAL_API_HOST=https://api.fleetros.local \
		--build-arg NEXT_PUBLIC_RENTAL_API_PORT=443 \
		--build-arg NEXT_PUBLIC_RECEIPT_API_PORT=443 \
		--build-arg NEXT_PUBLIC_USE_SAMPLE_DATA=false \
		--build-arg NEXT_PUBLIC_MAX_CARS_SELECTABLE=5 \
		-t $(CUSTOMER_IMAGE):$(CUSTOMER_TAG) \
		"$(CUSTOMER_REPO_DIR)" && \
		docker push $(CUSTOMER_IMAGE):$(CUSTOMER_TAG)

	@$(MAKE) --no-print-directory local-import-customer
	@$(MAKE) --no-print-directory local-rollout-customer

local-import-customer: ## Save fleetros-customer image and import it into k3s containerd inside the VM
	@TMP=$$(mktemp -d "$$HOME/fleetros-customer-XXXXXX"); TAR=$$TMP/customer.tar; \
	echo "Saving $(CUSTOMER_IMAGE):$(CUSTOMER_TAG) -> $$TAR"; \
	docker save -o $$TAR $(CUSTOMER_IMAGE):$(CUSTOMER_TAG); \
	echo "Transferring to $(VM_NAME)"; \
	multipass transfer $$TAR $(VM_NAME):/tmp/fleetros-customer.tar; \
	echo "Importing into k3s containerd (k8s.io namespace)"; \
	multipass exec $(VM_NAME) -- sudo /usr/local/bin/k3s ctr -n k8s.io images import /tmp/fleetros-customer.tar; \
	multipass exec $(VM_NAME) -- sudo rm -f /tmp/fleetros-customer.tar; \
	rm -rf $$TMP

local-rollout-customer: ## Restart fleetros-customer pods to pick up the freshly imported image
	@if KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app get deploy fleetros-customer >/dev/null 2>&1; then \
		KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app rollout restart deploy/fleetros-customer && \
		KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app rollout status  deploy/fleetros-customer --timeout=180s; \
	else \
		echo "WARN: deploy/fleetros-customer not found in namespace app."; \
		echo "      The customer subchart must be synced by Argo CD first."; \
		echo "      Steps: 1) git add/commit/push the gitops changes,"; \
		echo "             2) wait for Argo CD auto-sync (or run: argocd app sync fleetros-local),"; \
		echo "             3) run 'make local-customer-db-push' to apply the schema,"; \
		echo "             4) re-run 'make local-build-customer'."; \
	fi

local-customer-db-push: ## Apply the website-builder Drizzle schema to the in-cluster Postgres (port-forward + bun run db:push)
	@test -d "$(CUSTOMER_REPO_DIR)" || { echo "ERROR: CUSTOMER_REPO_DIR=$(CUSTOMER_REPO_DIR) not found."; exit 1; }
	@command -v bun >/dev/null 2>&1 || { echo "ERROR: bun not found on host (install: https://bun.sh)"; exit 1; }
	@echo "Fetching postgres-creds from app namespace..."
	@DB_USER=$$(KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app get secret postgres-creds -o jsonpath='{.data.POSTGRES_USER}' | base64 -d); \
	DB_PASSWORD=$$(KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app get secret postgres-creds -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d); \
	if [ -z "$$DB_USER" ] || [ -z "$$DB_PASSWORD" ]; then echo "ERROR: postgres-creds Secret missing or empty in 'app' namespace."; exit 1; fi; \
	echo "Port-forwarding postgres (sts) -> localhost:55432"; \
	KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n data port-forward sts/postgres 55432:5432 >/tmp/fleetros-pg-pf.log 2>&1 & \
	PF_PID=$$!; \
	trap "kill $$PF_PID 2>/dev/null || true" EXIT; \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		if (echo > /dev/tcp/127.0.0.1/55432) >/dev/null 2>&1; then break; fi; \
		sleep 1; \
	done; \
	if ! (echo > /dev/tcp/127.0.0.1/55432) >/dev/null 2>&1; then \
		echo "ERROR: port-forward did not become ready. Log:"; cat /tmp/fleetros-pg-pf.log; exit 1; \
	fi; \
	echo "Running 'bun run db:push' against website DB..."; \
	cd "$(CUSTOMER_REPO_DIR)" && \
		DB_HOST=127.0.0.1 DB_PORT=55432 DB_USER=$$DB_USER DB_PASSWORD=$$DB_PASSWORD DB_NAME=website \
		bun run db:push

local-logs-customer: ## Tail fleetros-customer logs
	KUBECONFIG=$(KUBECONFIG_LOCAL) kubectl -n app logs -f deploy/fleetros-customer --max-log-requests=10


LOCAL_HOSTS := app api portal reporting mail argocd customer-api auth traefik stackgres
# Published tenant subdomains for the website-builder. Append slugs here as
# you publish them (e.g. `LOCAL_TENANT_HOSTS := tripz-car-rental acme-rentals`)
# and re-run `make local-hosts-install`. /etc/hosts can't wildcard.
LOCAL_TENANT_HOSTS ?=
local-hosts-print: ## Print /etc/hosts line for *.fleetros.local (copy to your host)
	@VM_IP=$$(multipass info $(VM_NAME) | awk '/IPv4/ {print $$2; exit}'); \
	HOSTS=$$(for h in $(LOCAL_HOSTS); do echo -n "$$h.fleetros.local "; done); \
	TENANTS=$$(for t in $(LOCAL_TENANT_HOSTS); do echo -n "$$t.portal.fleetros.local "; done); \
	echo "$$VM_IP $$HOSTS$$TENANTS"

local-hosts-install: ## Install/refresh /etc/hosts entries for *.fleetros.local (sudo)
	@VM_IP=$$(multipass info $(VM_NAME) | awk '/IPv4/ {print $$2; exit}'); \
	if [ -z "$$VM_IP" ]; then \
	  echo "ERROR: could not determine VM IP via 'multipass info $(VM_NAME)'."; \
	  echo "Run this target WITHOUT sudo (it will sudo internally), and make sure"; \
	  echo "you've authenticated multipass for your user (see 'multipass authenticate')."; \
	  exit 1; \
	fi; \
	HOSTS=$$(for h in $(LOCAL_HOSTS); do echo -n "$$h.fleetros.local "; done); \
	TENANTS=$$(for t in $(LOCAL_TENANT_HOSTS); do echo -n "$$t.portal.fleetros.local "; done); \
	LINE="$$VM_IP $$HOSTS$$TENANTS# fleetros-local"; \
	echo "Updating /etc/hosts -> $$LINE"; \
	sudo sed -i.bak '/# fleetros-local$$/d' /etc/hosts; \
	echo "$$LINE" | sudo tee -a /etc/hosts >/dev/null; \
	echo "Done. Try: https://app.fleetros.local"

local-hosts-uninstall: ## Remove fleetros-local /etc/hosts entries (sudo)
	sudo sed -i.bak '/# fleetros-local$$/d' /etc/hosts
	@echo "Removed."

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
        local-argocd-ui local-argocd-portforward local-traefik-portforward local-k9s local-vm-ssh-trust \
        local-mkcert-check local-stackgres-ui local-stackgres-portforward \
        local-build-web local-import-web local-rollout-web local-logs-web \
        local-build-customer local-import-customer local-rollout-customer local-logs-customer local-customer-db-push
