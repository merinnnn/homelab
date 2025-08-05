#!/bin/bash
# Terraform deployment script with safety checks

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

echo -e "${BLUE}🚀 Homelab Infrastructure Deployment${NC}"
echo "====================================="

# Run validation first
echo -e "${BLUE}🔍 Running pre-deployment validation...${NC}"
if ! ./scripts/validate.sh; then
    echo -e "${RED}❌ Validation failed. Please fix issues before deploying.${NC}"
    exit 1
fi

# Check Proxmox connectivity
echo -e "${BLUE}🌐 Testing Proxmox connectivity...${NC}"
PROXMOX_HOST=$(grep 'proxmox_host' terraform.tfvars | cut -d'"' -f2)
if ping -c 1 -W 5 "$PROXMOX_HOST" &> /dev/null; then
    echo -e "${GREEN}✅ Proxmox host ($PROXMOX_HOST) is reachable${NC}"
else
    echo -e "${RED}❌ Cannot reach Proxmox host ($PROXMOX_HOST)${NC}"
    exit 1
fi

# Create deployment plan
echo -e "${BLUE}📋 Creating deployment plan...${NC}"
terraform plan -out=tfplan

# Show plan summary
echo ""
echo -e "${BLUE}📊 Deployment Summary:${NC}"
terraform show -json tfplan | jq -r '
  .resource_changes[] | 
  select(.change.actions[] | . == "create") | 
  "  + " + .type + "." + .name + " (" + .change.after.name + ")"
'

echo ""
echo -e "${YELLOW}⚠️  This will create the following resources:${NC}"
echo "  - Pi-hole VM (10.0.10.11)"
echo "  - Docker Host VM (10.0.10.21)"
echo ""

# Confirmation
read -p "Continue with deployment? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    rm -f tfplan
    exit 0
fi

# Apply deployment
echo -e "${BLUE}🎯 Applying deployment...${NC}"
if terraform apply tfplan; then
    echo -e "${GREEN}🎉 Deployment completed successfully!${NC}"
else
    echo -e "${RED}❌ Deployment failed${NC}"
    exit 1
fi

# Cleanup
rm -f tfplan

# Show results
echo ""
echo -e "${BLUE}📊 Deployment Results:${NC}"
terraform output

echo ""
echo -e "${GREEN}✅ Next Steps:${NC}"
echo "1. Wait 2-3 minutes for VMs to fully boot"
echo "2. Test SSH connectivity to VMs"
echo "3. Update Ansible inventory with VM IPs"
echo "4. Run Ansible playbooks to configure services"