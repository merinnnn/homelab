#!/bin/bash
# Update Ansible inventory from Terraform output

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$(dirname "$ANSIBLE_DIR")/terraform"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🔄 Updating Ansible Inventory from Terraform${NC}"
echo "=============================================="

cd "$ANSIBLE_DIR"

# Check if Terraform state exists
if [ ! -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
    echo -e "${RED}❌ Terraform state not found${NC}"
    echo "Please run Terraform first to create VMs"
    exit 1
fi

# Extract VM information from Terraform
echo -e "${BLUE}📊 Extracting VM information...${NC}"

cd "$TERRAFORM_DIR"

# Get Terraform outputs
if ! terraform output > /dev/null 2>&1; then
    echo -e "${RED}❌ No Terraform outputs found${NC}"
    exit 1
fi

PIHOLE_IP=$(terraform output -json pihole_vm_info | jq -r '.ip_address' 2>/dev/null || echo "")
DOCKER_IP=$(terraform output -json docker_host_vm_info | jq -r '.ip_address' 2>/dev/null || echo "")
VM_USER=$(terraform output -json ansible_inventory | jq -r '.all_vars.ansible_user' 2>/dev/null || echo "homelab")
SSH_KEY=$(terraform output -json ansible_inventory | jq -r '.all_vars.ansible_ssh_private_key_file' 2>/dev/null || echo "~/.ssh/id_rsa")

if [[ -z "$PIHOLE_IP" || -z "$DOCKER_IP" ]]; then
    echo -e "${RED}❌ Could not extract VM IPs from Terraform output${NC}"
    exit 1
fi

echo "Found VMs:"
echo "  Pi-hole: $PIHOLE_IP"
echo "  Docker:  $DOCKER_IP"
echo ""

# Generate new inventory
cd "$ANSIBLE_DIR"

echo -e "${BLUE}📝 Generating inventory...${NC}"

cat > inventory/hosts.yml << EOF
# Auto-generated inventory from Terraform
# Generated at: $(date)

all:
  vars:
    ansible_user: $VM_USER
    ansible_ssh_private_key_file: $SSH_KEY
    ansible_python_interpreter: /usr/bin/python3
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
  
  children:
    pihole:
      hosts:
        pihole-tf:
          ansible_host: $PIHOLE_IP
          pihole_password: "{{ vault_pihole_password | default('admin123') }}"
          
    docker_hosts:
      hosts:
        docker-host-tf:
          ansible_host: $DOCKER_IP
EOF

echo -e "${GREEN}✅ Inventory updated successfully${NC}"

# Validate new inventory
echo -e "${BLUE}🔍 Validating inventory...${NC}"
if ansible-inventory --list > /dev/null; then
    echo -e "${GREEN}✅ Inventory is valid${NC}"
else
    echo -e "${RED}❌ Generated inventory is invalid${NC}"
    exit 1
fi

# Test connectivity
echo -e "${BLUE}🌐 Testing connectivity...${NC}"
if ansible all -m ping --one-line; then
    echo -e "${GREEN}✅ All hosts reachable${NC}"
else
    echo -e "${YELLOW}⚠️  Some hosts not reachable yet${NC}"
    echo "This is normal if VMs were just created"
fi

echo ""
echo -e "${GREEN}🎉 Inventory update completed!${NC}"
echo ""
echo "Next steps:"
echo "1. Run: ./scripts/deploy.sh"
echo "2. Or run specific playbook: ./scripts/deploy.sh -p pihole-only.yml"