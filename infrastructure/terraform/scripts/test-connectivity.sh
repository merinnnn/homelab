#!/bin/bash
# Test connectivity to deployed VMs

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🧪 Testing VM Connectivity${NC}"
echo "=========================="

# Get IPs from terraform output
PIHOLE_IP=$(terraform output -raw pihole_vm_info | jq -r '.ip_address' 2>/dev/null || echo "10.0.10.11")
DOCKER_IP=$(terraform output -raw docker_host_vm_info | jq -r '.ip_address' 2>/dev/null || echo "10.0.10.21")
VM_USER=$(terraform output -raw pihole_vm_info | jq -r '.ssh_command' | cut -d'@' -f1 | cut -d' ' -f2 2>/dev/null || echo "homelab")

echo "Testing connectivity to:"
echo "  Pi-hole VM: $PIHOLE_IP"
echo "  Docker VM:  $DOCKER_IP"
echo ""

# Test ping connectivity
test_ping() {
    local ip=$1
    local name=$2
    
    echo -n "Testing ping to $name ($ip)... "
    if ping -c 1 -W 5 "$ip" &> /dev/null; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}FAILED${NC}"
        return 1
    fi
}

# Test SSH connectivity
test_ssh() {
    local ip=$1
    local name=$2
    local user=$3
    
    echo -n "Testing SSH to $name ($user@$ip)... "
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$user@$ip" "echo 'SSH OK'" &> /dev/null; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}FAILED${NC}"
        return 1
    fi
}

# Run tests
TESTS_PASSED=0
TESTS_FAILED=0

# Ping tests
if test_ping "$PIHOLE_IP" "Pi-hole VM"; then
    ((TESTS_PASSED++))
else
    ((TESTS_FAILED++))
fi

if test_ping "$DOCKER_IP" "Docker VM"; then
    ((TESTS_PASSED++))
else
    ((TESTS_FAILED++))
fi

echo ""

# SSH tests
if test_ssh "$PIHOLE_IP" "Pi-hole VM" "$VM_USER"; then
    ((TESTS_PASSED++))
else
    ((TESTS_FAILED++))
fi

if test_ssh "$DOCKER_IP" "Docker VM" "$VM_USER"; then
    ((TESTS_PASSED++))
else
    ((TESTS_FAILED++))
fi

echo ""
echo "Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 All connectivity tests passed!${NC}"
    echo ""
    echo "VMs are ready for Ansible configuration."
    exit 0
else
    echo -e "${RED}❌ Some tests failed.${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "1. Wait a few minutes for VMs to fully boot"
    echo "2. Check VM status in Proxmox console"
    echo "3. Verify network configuration on Proxmox host"
    exit 1
fi