#!/bin/bash
# Ultra-quick setup for experienced users

set -e

echo "🚀 Homelab Quick Start"
echo "====================="
echo ""

# Check if we're in the right directory
if [[ ! -d "terraform" || ! -d "ansible" ]]; then
    echo "❌ Please run this script from the infrastructure directory"
    exit 1
fi

# Quick prerequisite check
for tool in terraform ansible jq; do
    if ! command -v "$tool" &> /dev/null; then
        echo "❌ $tool not found. Run 'make install' first."
        exit 1
    fi
done

echo "1. Checking Terraform configuration..."
if [[ ! -f "terraform/terraform.tfvars" ]]; then
    echo "⚠️  Copying terraform.tfvars.example to terraform.tfvars"
    cp terraform/terraform.tfvars.example terraform/terraform.tfvars
    echo "❌ Please edit terraform/terraform.tfvars with your settings"
    exit 1
fi

echo "2. Initializing Terraform..."
cd terraform && terraform init && cd ..

echo "3. Creating infrastructure..."
cd terraform && terraform apply -auto-approve && cd ..

echo "4. Waiting for VMs to boot..."
sleep 60

echo "5. Updating Ansible inventory..."
cd ansible && ./scripts/update-inventory.sh && cd ..

echo "6. Configuring services..."
cd ansible && ansible-playbook playbooks/site.yml && cd ..

echo "7. Testing services..."
cd ansible && ./scripts/test-services.sh && cd ..

echo ""
echo "🎉 Quick setup complete!"
echo ""
echo "Access your services:"
echo "  Pi-hole: http://10.0.10.11/admin"
echo "  Portainer: http://10.0.10.21:9000"
echo "  Uptime Kuma: http://10.0.10.21:3001"