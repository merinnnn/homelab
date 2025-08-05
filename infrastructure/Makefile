# Makefile for homelab infrastructure management

.PHONY: help install validate plan deploy destroy clean test format security

# Default target
help: ## Show this help message
	@echo "Homelab Infrastructure Management"
	@echo "================================"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $1, $2}'
	@echo ""
	@echo "Examples:"
	@echo "  make install     # Install required tools"
	@echo "  make deploy      # Full deployment"
	@echo "  make test        # Run all tests"
	@echo "  make destroy     # Destroy infrastructure"

install: ## Install required tools and dependencies
	@echo "🔧 Installing required tools..."
	@command -v terraform >/dev/null 2>&1 || { echo "Installing Terraform..."; curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -; sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"; sudo apt-get update && sudo apt-get install terraform; }
	@command -v ansible >/dev/null 2>&1 || { echo "Installing Ansible..."; sudo apt-get update && sudo apt-get install -y ansible; }
	@command -v jq >/dev/null 2>&1 || { echo "Installing jq..."; sudo apt-get install -y jq; }
	@ansible-galaxy collection list community.docker >/dev/null 2>&1 || ansible-galaxy collection install community.docker
	@echo "✅ All tools installed"

validate: ## Validate Terraform and Ansible configurations
	@echo "🔍 Validating configurations..."
	@cd terraform && ./scripts/validate.sh
	@cd ansible && ./scripts/validate.sh
	@echo "✅ Validation complete"

plan: ## Create Terraform deployment plan
	@echo "📋 Creating Terraform plan..."
	@cd terraform && terraform init && terraform plan -out=tfplan
	@echo "✅ Plan created (saved as tfplan)"

deploy: ## Deploy complete infrastructure
	@echo "🚀 Deploying infrastructure..."
	@./setup.sh

deploy-terraform: ## Deploy only Terraform resources
	@echo "🏗️ Deploying Terraform resources..."
	@./setup.sh --terraform-only

deploy-ansible: ## Deploy only Ansible configuration
	@echo "🔧 Deploying Ansible configuration..."
	@./setup.sh --ansible-only

deploy-auto: ## Deploy with auto-approval (dangerous!)
	@echo "🚀 Auto-deploying infrastructure..."
	@./setup.sh --auto-approve

test: ## Run all tests and validations
	@echo "🧪 Running all tests..."
	@cd terraform && ./scripts/validate.sh && ./scripts/test-connectivity.sh
	@cd ansible && ./scripts/validate.sh && ./scripts/test-services.sh
	@echo "✅ All tests completed"

test-connectivity: ## Test VM connectivity
	@echo "🌐 Testing connectivity..."
	@cd terraform && ./scripts/test-connectivity.sh

test-services: ## Test deployed services
	@echo "🧪 Testing services..."
	@cd ansible && ./scripts/test-services.sh

format: ## Format Terraform and Ansible code
	@echo "🎨 Formatting code..."
	@cd terraform && terraform fmt -recursive
	@echo "✅ Code formatted"

security: ## Run security scans
	@echo "🔒 Running security scans..."
	@command -v tfsec >/dev/null 2>&1 && cd terraform && tfsec . || echo "⚠️ tfsec not installed, skipping Terraform security scan"
	@command -v ansible-lint >/dev/null 2>&1 && cd ansible && ansible-lint playbooks/ || echo "⚠️ ansible-lint not installed, skipping Ansible linting"
	@echo "✅ Security scans completed"

clean: ## Clean temporary files and caches
	@echo "🧹 Cleaning temporary files..."
	@find . -name "*.tfplan" -delete
	@find . -name ".terraform" -type d -exec rm -rf {} + 2>/dev/null || true
	@find . -name "*.retry" -delete
	@echo "✅ Cleanup completed"

destroy: ## Destroy all infrastructure (DANGEROUS!)
	@echo "🗑️ WARNING: This will destroy all infrastructure!"
	@read -p "Are you sure? Type 'yes' to confirm: " confirm && [ "$confirm" = "yes" ] || exit 1
	@cd terraform && ./scripts/destroy.sh

destroy-auto: ## Auto-destroy infrastructure (VERY DANGEROUS!)
	@echo "🗑️ Auto-destroying infrastructure..."
	@cd terraform && terraform destroy -auto-approve

status: ## Show infrastructure status
	@echo "📊 Infrastructure Status"
	@echo "======================="
	@echo ""
	@if [ -f terraform/terraform.tfstate ]; then \
		echo "🏗️ Terraform State:"; \
		cd terraform && terraform show -json | jq -r '.values.root_module.resources[]? | select(.type == "proxmox_vm_qemu") | "  " + .values.name + " (ID: " + (.values.vmid | tostring) + ")"'; \
		echo ""; \
	else \
		echo "❌ No Terraform state found"; \
	fi
	@echo "🔧 Service Status:"
	@cd ansible && ansible all -m ping --one-line 2>/dev/null || echo "  ❌ VMs not reachable"

logs: ## Show recent logs
	@echo "📋 Recent Infrastructure Logs"
	@echo "============================="
	@echo ""
	@echo "🏗️ Terraform Logs:"
	@find terraform -name "*.log" -exec tail -n 5 {} \; 2>/dev/null || echo "  No Terraform logs found"
	@echo ""
	@echo "🔧 Ansible Logs:"
	@find ansible -name "*.log" -exec tail -n 5 {} \; 2>/dev/null || echo "  No Ansible logs found"

backup: ## Backup current state
	@echo "💾 Creating backup..."
	@mkdir -p backups
	@tar -czf backups/homelab-backup-$(date +%Y%m%d-%H%M%S).tar.gz \
		terraform/terraform.tfstate* \
		terraform/terraform.tfvars \
		ansible/inventory/ \
		ansible/group_vars/ 2>/dev/null || true
	@echo "✅ Backup created in backups/"

restore: ## Restore from backup
	@echo "📂 Available backups:"
	@ls -la backups/ 2>/dev/null || echo "No backups found"
	@read -p "Enter backup filename to restore: " backup && \
		tar -xzf "backups/$backup" && \
		echo "✅ Backup restored"

update-inventory: ## Update Ansible inventory from Terraform
	@echo "🔄 Updating Ansible inventory..."
	@cd ansible && ./scripts/update-inventory.sh

ssh-pihole: ## SSH into Pi-hole VM
	@cd terraform && ssh $(terraform output -raw ssh_connections | jq -r '.pihole')

ssh-docker: ## SSH into Docker VM
	@cd terraform && ssh $(terraform output -raw ssh_connections | jq -r '.docker_host')

monitoring: ## Open monitoring dashboard
	@echo "🖥️ Opening monitoring services..."
	@cd terraform && \
		DOCKER_IP=$(terraform output -json docker_host_vm_info | jq -r '.ip_address') && \
		echo "Opening Portainer: http://$DOCKER_IP:9000" && \
		echo "Opening Uptime Kuma: http://$DOCKER_IP:3001"

# Advanced targets
init: install ## Initialize project (install tools and validate)
	@echo "🚀 Initializing homelab project..."
	@cd terraform && terraform init
	@$(MAKE) validate
	@echo "✅ Project initialized"

upgrade: ## Upgrade infrastructure components
	@echo "⬆️ Upgrading infrastructure..."
	@cd terraform && terraform init -upgrade
	@cd ansible && ansible-galaxy collection install community.docker --upgrade
	@echo "✅ Upgrade completed"

docs: ## Generate documentation
	@echo "📚 Generating documentation..."
	@cd terraform && terraform-docs markdown table . > terraform-docs.md 2>/dev/null || echo "terraform-docs not installed"
	@echo "✅ Documentation generated"

# Development targets
dev-setup: ## Set up development environment
	@echo "🛠️ Setting up development environment..."
	@$(MAKE) install
	@command -v pre-commit >/dev/null 2>&1 || pip3 install pre-commit
	@command -v tfsec >/dev/null 2>&1 || { echo "Installing tfsec..."; curl -s https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash; }
	@command -v ansible-lint >/dev/null 2>&1 || pip3 install ansible-lint
	@echo "✅ Development environment ready"

lint: ## Run all linters
	@echo "🔍 Running linters..."
	@cd terraform && terraform fmt -check -diff
	@command -v tfsec >/dev/null 2>&1 && cd terraform && tfsec . || echo "⚠️ tfsec not installed"
	@command -v ansible-lint >/dev/null 2>&1 && cd ansible && ansible-lint playbooks/ || echo "⚠️ ansible-lint not installed"
	@echo "✅ Linting completed"
