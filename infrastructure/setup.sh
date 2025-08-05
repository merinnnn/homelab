#!/bin/bash
# One-click setup script for homelab infrastructure

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"

echo -e "${BLUE}🚀 Homelab Infrastructure Setup${NC}"
echo "==============================="
echo ""

# Parse command line arguments
SKIP_VALIDATION=false
AUTO_APPROVE=false
DEPLOY_ONLY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        --auto-approve)
            AUTO_APPROVE=true
            shift
            ;;
        --terraform-only)
            DEPLOY_ONLY="terraform"
            shift
            ;;
        --ansible-only)
            DEPLOY_ONLY="ansible"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --skip-validation   Skip pre-deployment validation"
            echo "  --auto-approve      Auto-approve all prompts"
            echo "  --terraform-only    Deploy only Terraform resources"
            echo "  --ansible-only      Deploy only Ansible configuration"
            echo "  -h, --help          Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
check_prerequisites() {
    echo -e "${BLUE}🔍 Checking prerequisites...${NC}"
    
    local missing_tools=()
    
    # Check required tools
    for tool in terraform ansible jq curl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo -e "${RED}❌ Missing required tools: ${missing_tools[*]}${NC}"
        echo ""
        echo "Install missing tools:"
        echo "  Terraform: https://developer.hashicorp.com/terraform/downloads"
        echo "  Ansible: pip3 install ansible"
        echo "  jq: sudo apt install jq"
        echo "  curl: sudo apt install curl"
        exit 1
    fi
    
    echo -e "${GREEN}✅ All required tools installed${NC}"
}

# Validate configuration
validate_configuration() {
    if [ "$SKIP_VALIDATION" = true ]; then
        echo -e "${YELLOW}⚠️  Skipping validation${NC}"
        return 0
    fi
    
    echo -e "${BLUE}🔍 Validating configuration...${NC}"
    
    # Validate Terraform
    if [[ "$DEPLOY_ONLY" != "ansible" ]]; then
        cd "$TERRAFORM_DIR"
        if ! ./scripts/validate.sh; then
            echo -e "${RED}❌ Terraform validation failed${NC}"
            exit 1
        fi
    fi
    
    # Validate Ansible
    if [[ "$DEPLOY_ONLY" != "terraform" ]]; then
        cd "$ANSIBLE_DIR"
        if ! ./scripts/validate.sh; then
            echo -e "${YELLOW}⚠️  Ansible validation issues (may be normal if VMs don't exist yet)${NC}"
        fi
    fi
    
    echo -e "${GREEN}✅ Configuration validated${NC}"
}

# Deploy Terraform infrastructure
deploy_terraform() {
    echo -e "${BLUE}🏗️  Deploying Terraform infrastructure...${NC}"
    
    cd "$TERRAFORM_DIR"
    
    if [ "$AUTO_APPROVE" = true ]; then
        terraform apply -auto-approve
    else
        ./scripts/deploy.sh
    fi
    
    # Wait for VMs to be ready
    echo -e "${BLUE}⏳ Waiting for VMs to be ready...${NC}"
    sleep 30
    
    # Test connectivity
    if ! ./scripts/test-connectivity.sh; then
        echo -e "${YELLOW}⚠️  Some connectivity tests failed. VMs may need more time to boot.${NC}"
        sleep 60
    fi
}

# Deploy Ansible configuration
deploy_ansible() {
    echo -e "${BLUE}🔧 Deploying Ansible configuration...${NC}"
    
    cd "$ANSIBLE_DIR"
    
    # Update inventory from Terraform
    if [[ "$DEPLOY_ONLY" != "ansible" ]]; then
        ./scripts/update-inventory.sh
    fi
    
    # Deploy services
    if [ "$AUTO_APPROVE" = true ]; then
        ansible-playbook playbooks/site.yml
    else
        ./scripts/deploy.sh
    fi
}

# Show final results
show_results() {
    echo ""
    echo -e "${GREEN}🎉 Deployment Complete!${NC}"
    echo "======================="
    
    if [[ "$DEPLOY_ONLY" != "ansible" ]]; then
        cd "$TERRAFORM_DIR"
        echo ""
        echo -e "${BLUE}📊 Infrastructure:${NC}"
        terraform output -json | jq -r '
            .pihole_vm_info.value as $pihole |
            .docker_host_vm_info.value as $docker |
            "  Pi-hole VM:   " + $pihole.name + " (" + $pihole.ip_address + ")",
            "  Docker VM:    " + $docker.name + " (" + $docker.ip_address + ")"
        '
    fi
    
    if [[ "$DEPLOY_ONLY" != "terraform" ]]; then
        cd "$ANSIBLE_DIR"
        echo ""
        echo -e "${BLUE}🌐 Service URLs:${NC}"
        
        # Get IPs from inventory
        PIHOLE_IP=$(ansible-inventory --list | jq -r '.pihole.hosts["pihole-tf"]' 2>/dev/null || echo "10.0.10.11")
        DOCKER_IP=$(ansible-inventory --list | jq -r '.docker_hosts.hosts["docker-host-tf"]' 2>/dev/null || echo "10.0.10.21")
        
        echo "  Pi-hole Admin: http://$PIHOLE_IP/admin"
        echo "  Portainer:     http://$DOCKER_IP:9000"
        echo "  Uptime Kuma:   http://$DOCKER_IP:3001"
        
        # Test services
        echo ""
        echo -e "${BLUE}🧪 Running service tests...${NC}"
        if ./scripts/test-services.sh; then
            echo -e "${GREEN}✅ All services are healthy!${NC}"
        else
            echo -e "${YELLOW}⚠️  Some services may need additional time to start${NC}"
        fi
    fi
    
    echo ""
    echo -e "${BLUE}📋 Next Steps:${NC}"
    echo "1. Access services using the URLs above"
    echo "2. Configure Pi-hole admin password"
    echo "3. Set up monitoring in Uptime Kuma"
    echo "4. Configure external port forwarding on Proxmox host"
    echo ""
    echo "For external access, run on Proxmox host:"
    echo "  curl -sSL https://raw.githubusercontent.com/merinnnn/homelab/main/scripts/proxmox/setup-port-forwarding.sh | bash"
}

# Main execution
main() {
    check_prerequisites
    validate_configuration
    
    # Deployment based on options
    case "$DEPLOY_ONLY" in
        "terraform")
            deploy_terraform
            ;;
        "ansible")
            deploy_ansible
            ;;
        *)
            deploy_terraform
            deploy_ansible
            ;;
    esac
    
    show_results
}

# Run main function
main "$@"