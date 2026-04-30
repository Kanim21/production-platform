.DEFAULT_GOAL := help
SHELL         := /bin/bash -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

AWS_REGION     ?= us-east-1
ENV            ?= dev
TF_DIR          = terraform/environments/$(ENV)
APP_DIR         = app
K8S_DIR         = kubernetes

# Override in CI or set locally: export AWS_ACCOUNT_ID=012345678901
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
ECR_REGISTRY    = $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

GIT_SHA        := $(shell git rev-parse --short HEAD 2>/dev/null || echo "dev")

# ── Colors ────────────────────────────────────────────────────────────────────

BOLD  = \033[1m
RESET = \033[0m
GREEN = \033[32m
BLUE  = \033[34m
RED   = \033[31m

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help message
	@echo -e "$(BOLD)production-platform$(RESET)"
	@echo -e "$(BLUE)Usage: make [target] [ENV=dev|staging|prod]$(RESET)\n"
	@awk 'BEGIN {FS = ":.*##"; printf ""} /^[a-zA-Z_-]+:.*?##/ { printf "  $(GREEN)%-25s$(RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ── Prerequisites check ───────────────────────────────────────────────────────

.PHONY: check-deps
check-deps: ## Verify required tools are installed
	@echo -e "$(BOLD)Checking dependencies...$(RESET)"
	@command -v aws       >/dev/null || (echo "$(RED)ERROR: aws CLI not found$(RESET)" && exit 1)
	@command -v terraform >/dev/null || (echo "$(RED)ERROR: terraform not found$(RESET)" && exit 1)
	@command -v kubectl   >/dev/null || (echo "$(RED)ERROR: kubectl not found$(RESET)" && exit 1)
	@command -v helm      >/dev/null || (echo "$(RED)ERROR: helm not found$(RESET)" && exit 1)
	@command -v docker    >/dev/null || (echo "$(RED)ERROR: docker not found$(RESET)" && exit 1)
	@command -v go        >/dev/null || (echo "$(RED)ERROR: go not found$(RESET)" && exit 1)
	@command -v node      >/dev/null || (echo "$(RED)ERROR: node not found$(RESET)" && exit 1)
	@aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null | grep -q 'arn:aws' || \
		(echo "$(RED)ERROR: AWS credentials not configured$(RESET)" && exit 1)
	@echo -e "$(GREEN)All dependencies OK$(RESET)"
	@echo -e "  AWS Account: $(AWS_ACCOUNT_ID)"
	@echo -e "  TF Version:  $$(terraform version -json | jq -r '.terraform_version')"
	@echo -e "  kubectl:     $$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')"

# ── Bootstrap ─────────────────────────────────────────────────────────────────

.PHONY: bootstrap-state
bootstrap-state: check-deps ## Create S3 + DynamoDB backend for ENV (run once per environment)
	@echo -e "$(BOLD)Bootstrapping Terraform state backend for $(ENV)...$(RESET)"
	@BUCKET="production-platform-tfstate-$(ENV)"; \
	aws s3api create-bucket \
		--bucket $$BUCKET \
		--region $(AWS_REGION) \
		--create-bucket-configuration LocationConstraint=$(AWS_REGION) \
		2>/dev/null || echo "Bucket already exists"; \
	aws s3api put-bucket-versioning \
		--bucket $$BUCKET \
		--versioning-configuration Status=Enabled; \
	aws s3api put-bucket-encryption \
		--bucket $$BUCKET \
		--server-side-encryption-configuration \
		'{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'; \
	aws s3api put-public-access-block \
		--bucket $$BUCKET \
		--public-access-block-configuration \
		'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'; \
	aws dynamodb create-table \
		--table-name production-platform-tfstate-lock \
		--attribute-definitions AttributeName=LockID,AttributeType=S \
		--key-schema AttributeName=LockID,KeyType=HASH \
		--billing-mode PAY_PER_REQUEST \
		--region $(AWS_REGION) \
		2>/dev/null || echo "DynamoDB table already exists"; \
	echo -e "$(GREEN)State backend ready$(RESET)"

# ── Terraform ─────────────────────────────────────────────────────────────────

.PHONY: init
init: check-deps ## Terraform init for ENV
	@echo -e "$(BOLD)terraform init [$(ENV)]$(RESET)"
	cd $(TF_DIR) && terraform init

.PHONY: plan
plan: check-deps ## Terraform plan for ENV
	@echo -e "$(BOLD)terraform plan [$(ENV)]$(RESET)"
	cd $(TF_DIR) && terraform plan \
		-var="pagerduty_sns_endpoint=$${PAGERDUTY_SNS_ENDPOINT:-}" \
		-var="slack_sns_endpoint=$${SLACK_SNS_ENDPOINT:-}"

.PHONY: apply
apply: check-deps ## Terraform apply for ENV (prompts for confirmation)
	@echo -e "$(BOLD)terraform apply [$(ENV)]$(RESET)"
	@if [ "$(ENV)" = "prod" ]; then \
		read -p "⚠️  Applying to PROD. Type 'prod' to confirm: " CONFIRM; \
		[ "$$CONFIRM" = "prod" ] || (echo "Aborted." && exit 1); \
	fi
	cd $(TF_DIR) && terraform apply \
		-var="pagerduty_sns_endpoint=$${PAGERDUTY_SNS_ENDPOINT:-}" \
		-var="slack_sns_endpoint=$${SLACK_SNS_ENDPOINT:-}"

.PHONY: destroy
destroy: ## Terraform destroy for ENV (requires double confirmation)
	@echo -e "$(RED)$(BOLD)WARNING: This will DESTROY all resources in $(ENV)$(RESET)"
	@read -p "Type the environment name to confirm: " CONFIRM1; \
	[ "$$CONFIRM1" = "$(ENV)" ] || (echo "Aborted." && exit 1)
	@read -p "Type 'destroy' to confirm: " CONFIRM2; \
	[ "$$CONFIRM2" = "destroy" ] || (echo "Aborted." && exit 1)
	cd $(TF_DIR) && terraform destroy \
		-var="pagerduty_sns_endpoint=$${PAGERDUTY_SNS_ENDPOINT:-}" \
		-var="slack_sns_endpoint=$${SLACK_SNS_ENDPOINT:-}"

# ── Kubeconfig ────────────────────────────────────────────────────────────────

.PHONY: kubeconfig
kubeconfig: ## Update kubeconfig for ENV
	@CLUSTER=$$(cd $(TF_DIR) && terraform output -raw eks_cluster_name); \
	aws eks update-kubeconfig \
		--region $(AWS_REGION) \
		--name $$CLUSTER \
		--alias production-platform-$(ENV)
	@echo -e "$(GREEN)Kubeconfig updated. Current context: $$(kubectl config current-context)$(RESET)"

# ── Database Migrations ───────────────────────────────────────────────────────

.PHONY: migrate
migrate: ## Run DB migrations against ENV
	@SECRET_ARN=$$(cd $(TF_DIR) && terraform output -raw db_credentials_secret_arn); \
	SECRET=$$(aws secretsmanager get-secret-value --secret-id $$SECRET_ARN --query SecretString --output text); \
	HOST=$$(echo $$SECRET | jq -r '.host'); \
	USER=$$(echo $$SECRET | jq -r '.username'); \
	PASS=$$(echo $$SECRET | jq -r '.password'); \
	DB=$$(echo $$SECRET | jq -r '.dbname'); \
	PGPASSWORD=$$PASS psql \
		-h $$HOST -U $$USER -d $$DB \
		-f $(APP_DIR)/db/migrations/001_init.sql
	@echo -e "$(GREEN)Migrations complete$(RESET)"

# ── Docker / ECR ──────────────────────────────────────────────────────────────

.PHONY: ecr-login
ecr-login: ## Authenticate Docker to ECR
	aws ecr get-login-password --region $(AWS_REGION) | \
		docker login --username AWS --password-stdin $(ECR_REGISTRY)

.PHONY: build-api
build-api: ## Build the Go API Docker image
	docker build \
		-t $(ECR_REGISTRY)/production-platform/api:$(GIT_SHA) \
		-t $(ECR_REGISTRY)/production-platform/api:latest \
		--build-arg VERSION=$(GIT_SHA) \
		$(APP_DIR)/api

.PHONY: build-web
build-web: ## Build the React web Docker image
	docker build \
		-t $(ECR_REGISTRY)/production-platform/web:$(GIT_SHA) \
		-t $(ECR_REGISTRY)/production-platform/web:latest \
		$(APP_DIR)/web

.PHONY: push-images
push-images: ecr-login build-api build-web ## Build and push all images to ECR
	docker push $(ECR_REGISTRY)/production-platform/api:$(GIT_SHA)
	docker push $(ECR_REGISTRY)/production-platform/api:latest
	docker push $(ECR_REGISTRY)/production-platform/web:$(GIT_SHA)
	docker push $(ECR_REGISTRY)/production-platform/web:latest
	@echo -e "$(GREEN)Images pushed: $(GIT_SHA)$(RESET)"

# ── Helm Deployments ──────────────────────────────────────────────────────────

.PHONY: helm-add-repos
helm-add-repos: ## Add required Helm repositories
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add aws-load-balancer-controller https://aws.github.io/eks-charts
	helm repo update

.PHONY: deploy-monitoring
deploy-monitoring: kubeconfig helm-add-repos ## Deploy kube-prometheus-stack to ENV
	helm upgrade --install kube-prometheus-stack \
		prometheus-community/kube-prometheus-stack \
		--namespace monitoring \
		--create-namespace \
		--version 61.7.1 \
		-f $(K8S_DIR)/monitoring/values.yaml \
		--wait \
		--timeout 15m
	@echo -e "$(GREEN)Monitoring stack deployed$(RESET)"

.PHONY: deploy-app
deploy-app: kubeconfig ## Deploy the application to ENV
	@IRSA_ARN=$$(aws iam get-role \
		--role-name production-platform-$(ENV)-api-irsa \
		--query 'Role.Arn' --output text 2>/dev/null || echo ""); \
	helm upgrade --install production-platform-app \
		$(K8S_DIR)/app \
		--namespace app \
		--create-namespace \
		--set image.registry=$(ECR_REGISTRY) \
		--set image.tag=$(GIT_SHA) \
		--set "api.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$$IRSA_ARN" \
		--wait \
		--timeout 10m
	@echo -e "$(GREEN)Application deployed: $(GIT_SHA)$(RESET)"

# ── One-Command Bootstrap ─────────────────────────────────────────────────────

.PHONY: dev-up
dev-up: check-deps ## Bootstrap the full dev environment end-to-end
	@echo -e "$(BOLD)Bootstrapping dev environment...$(RESET)"
	@$(MAKE) bootstrap-state ENV=dev
	@$(MAKE) init ENV=dev
	@$(MAKE) apply ENV=dev
	@$(MAKE) kubeconfig ENV=dev
	@$(MAKE) push-images
	@$(MAKE) deploy-monitoring ENV=dev
	@$(MAKE) migrate ENV=dev
	@$(MAKE) deploy-app ENV=dev
	@echo ""
	@echo -e "$(GREEN)$(BOLD)Dev environment ready!$(RESET)"
	@echo -e "  Run: kubectl get ingress -n app  # to get the ALB URL"
	@echo -e "  Run: make grafana-port-forward   # to open Grafana"

.PHONY: dev-down
dev-down: ## Tear down the dev environment
	@$(MAKE) destroy ENV=dev

# ── Developer Utilities ───────────────────────────────────────────────────────

.PHONY: grafana-port-forward
grafana-port-forward: kubeconfig ## Port-forward Grafana to localhost:3000
	@echo "Grafana available at http://localhost:3000 (admin/prom-operator)"
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

.PHONY: api-logs
api-logs: kubeconfig ## Stream API pod logs
	kubectl logs -n app -l app.kubernetes.io/component=api -f --tail=100

.PHONY: db-shell
db-shell: ## Open a psql shell to the ENV database
	@SECRET_ARN=$$(cd $(TF_DIR) && terraform output -raw db_credentials_secret_arn); \
	SECRET=$$(aws secretsmanager get-secret-value --secret-id $$SECRET_ARN --query SecretString --output text); \
	HOST=$$(echo $$SECRET | jq -r '.host'); \
	USER=$$(echo $$SECRET | jq -r '.username'); \
	PASS=$$(echo $$SECRET | jq -r '.password'); \
	DB=$$(echo $$SECRET | jq -r '.dbname'); \
	PGPASSWORD=$$PASS psql -h $$HOST -U $$USER -d $$DB

.PHONY: test-api
test-api: ## Run Go API unit tests
	cd $(APP_DIR)/api && go test ./... -race -count=1 -v

.PHONY: lint
lint: ## Run tflint + Checkov locally
	@echo -e "$(BOLD)Running tflint...$(RESET)"
	@for dir in terraform/modules/*/ terraform/environments/*/; do \
		echo "  $$dir"; \
		tflint --chdir="$$dir" || exit 1; \
	done
	@echo -e "$(BOLD)Running Checkov...$(RESET)"
	checkov -d terraform/ --framework terraform --quiet

.PHONY: fmt
fmt: ## Run terraform fmt and go fmt
	terraform fmt -recursive terraform/
	cd $(APP_DIR)/api && gofmt -l -w .

.PHONY: docs
docs: ## Generate Terraform module documentation with terraform-docs
	@for dir in terraform/modules/*/; do \
		echo "Generating docs for $$dir"; \
		terraform-docs markdown table --output-file README.md --output-mode inject "$$dir" 2>/dev/null || true; \
	done

# ── Status / Debug ────────────────────────────────────────────────────────────

.PHONY: status
status: kubeconfig ## Show cluster status for ENV
	@echo -e "$(BOLD)Nodes:$(RESET)"
	@kubectl get nodes -o wide
	@echo -e "\n$(BOLD)Pods (app namespace):$(RESET)"
	@kubectl get pods -n app -o wide
	@echo -e "\n$(BOLD)Pods (monitoring namespace):$(RESET)"
	@kubectl get pods -n monitoring
	@echo -e "\n$(BOLD)Ingresses:$(RESET)"
	@kubectl get ingress -A
	@echo -e "\n$(BOLD)HPA:$(RESET)"
	@kubectl get hpa -A

.PHONY: costs
costs: ## Estimate infrastructure costs with Infracost
	@command -v infracost >/dev/null || (echo "Install infracost: https://www.infracost.io/docs/" && exit 1)
	infracost breakdown --path $(TF_DIR) \
		--terraform-var "pagerduty_sns_endpoint=placeholder" \
		--terraform-var "slack_sns_endpoint=placeholder"
