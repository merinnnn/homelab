#!/bin/bash
# Ansible validation and testing script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🔍 Ansible Configuration Validation${NC}"
echo "===================================="

cd "$ANSIBLE_DIR"

# Check if ansible is installed
if ! command -v ansible &> /dev/null; then
    echo -e "${RED}❌ Ansible is not installed${NC}"
    echo "Install with: pip3 install ansible"
    exit 1
fi

echo -e "${GREEN}✅ Ansible installed:${NC} $(ansible --version | head -1)"

# Check if required collections are installed
echo -e "${BLUE}📦 Checking Ansible collections...${NC}"
if ansible-galaxy collection list community.docker &> /dev/null; then
    echo -e "${GREEN}✅ community.docker collection installed${NC}"
else
    echo -e "${YELLOW}⚠️  Installing community.docker collection...${NC}"
    ansible-galaxy collection install community.docker
fi

# Validate inventory
echo -e "${BLUE}🔍 Validating inventory...${NC}"
if ansible-inventory --list > /dev/null; then
    echo -e "${GREEN}✅ Inventory is valid${NC}"
else
    echo -e "${RED}❌ Inventory validation failed${NC}"
    exit 1
fi

# Check inventory hosts
echo -e "${BLUE}📋 Inventory hosts:${NC}"
ansible-inventory --list | jq -r '.all.children | keys[]' | while read group; do
    echo "  Group: $group"
    ansible-inventory --list | jq -r ".${group}.hosts // [] | keys[]" | while read host; do
        echo "    - $host"
    done
done

# Validate playbooks syntax
echo -e "${BLUE}🔍 Validating playbook syntax...${NC}"
for playbook in playbooks/*.yml; do
    if [ -f "$playbook" ]; then
        echo -n "  Checking $(basename "$playbook")... "
        if ansible-playbook --syntax-check "$playbook" > /dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            exit 1
        fi
    fi
done

# Test connection to hosts
echo -e "${BLUE}🌐 Testing host connectivity...${NC}"
if ansible all -m ping --one-line; then
    echo -e "${GREEN}✅ All hosts reachable${NC}"
else
    echo -e "${YELLOW}⚠️  Some hosts unreachable${NC}"
    echo "This is normal if VMs are not yet configured"
fi

echo ""
echo -e "${GREEN}🎉 Ansible validation completed!${NC}"
