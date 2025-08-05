#!/bin/bash
# Terraform destroy script with safety checks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "$TERRAFORM_DIR"

echo -e "${RED}🗑️  Homelab Infrastructure Destruction${NC}"
echo "======================================"

# Show current resources
echo -e "${BLUE}📊 Current Resources:${NC}"
terraform show | grep -E "resource \"proxmox_vm_qemu\"" || echo "No resources found"

echo ""
echo -e "${RED}⚠️  WARNING: This will DESTROY all Terraform-managed resources!${NC}"
echo "This includes:"
echo "  - Pi-hole VM and all its data"
echo "  - Docker Host VM and all containers/data"
echo ""

# Double confirmation
read -p "Are you ABSOLUTELY sure you want to destroy everything? (type 'yes' to confirm): " -r
if [[ ! $REPLY == "yes" ]]; then
    echo "Destruction cancelled."
    exit 0
fi

echo -e "${YELLOW}Last chance to cancel...${NC}"
sleep 3

# Create destroy plan
echo -e "${BLUE}📋 Creating destruction plan...${NC}"
terraform plan -destroy -out=destroy-plan

# Apply destruction
echo -e "${RED}🗑️  Destroying infrastructure...${NC}"
if terraform apply destroy-plan; then
    echo -e "${GREEN}✅ Infrastructure destroyed successfully${NC}"
else
    echo -e "${RED}❌ Destruction failed${NC}"
    exit 1
fi

# Cleanup
rm -f destroy-plan

echo ""
echo -e "${GREEN}🎉 Cleanup completed!${NC}"