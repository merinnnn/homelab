#!/bin/bash
# Terraform validation and testing script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🔍 Terraform Configuration Validation${NC}"
echo "======================================"

cd "$TERRAFORM_DIR"

# Check if terraform is installed
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}❌ Terraform is not installed${NC}"
    echo "Please install Terraform: https://developer.hashicorp.com/terraform/downloads"
    exit 1
fi

echo -e "${GREEN}✅ Terraform installed:${NC} $(terraform version -json | jq -r '.terraform_version')"

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    echo -e "${YELLOW}⚠️  terraform.tfvars not found${NC}"
    echo "Creating from example..."
    if [ -f "terraform.tfvars.example" ]; then
        cp terraform.tfvars.example terraform.tfvars
        echo -e "${YELLOW}⚠️  Please edit terraform.tfvars with your values${NC}"
    else
        echo -e "${RED}❌ terraform.tfvars.example not found${NC}"
        exit 1
    fi
fi

# Validate SSH key exists
SSH_KEY_PATH=$(grep 'ssh_public_key_path' terraform.tfvars | cut -d'"' -f2 | sed "s|~|$HOME|")
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo -e "${RED}❌ SSH public key not found: $SSH_KEY_PATH${NC}"
    echo "Generate SSH key with: ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa"
    exit 1
fi

echo -e "${GREEN}✅ SSH key found:${NC} $SSH_KEY_PATH"

# Initialize Terraform
echo -e "${BLUE}📦 Initializing Terraform...${NC}"
if terraform init; then
    echo -e "${GREEN}✅ Terraform initialized${NC}"
else
    echo -e "${RED}❌ Terraform initialization failed${NC}"
    exit 1
fi

# Validate configuration
echo -e "${BLUE}🔍 Validating configuration...${NC}"
if terraform validate; then
    echo -e "${GREEN}✅ Configuration is valid${NC}"
else
    echo -e "${RED}❌ Configuration validation failed${NC}"
    exit 1
fi

# Format check
echo -e "${BLUE}🎨 Checking formatting...${NC}"
if terraform fmt -check -diff; then
    echo -e "${GREEN}✅ Formatting is correct${NC}"
else
    echo -e "${YELLOW}⚠️  Formatting issues found. Run 'terraform fmt' to fix${NC}"
fi

# Security scan (if tfsec is available)
if command -v tfsec &> /dev/null; then
    echo -e "${BLUE}🔒 Running security scan...${NC}"
    if tfsec .; then
        echo -e "${GREEN}✅ Security scan passed${NC}"
    else
        echo -e "${YELLOW}⚠️  Security issues found${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  tfsec not installed, skipping security scan${NC}"
fi

# Plan validation (dry run)
echo -e "${BLUE}📋 Creating plan (dry run)...${NC}"
if terraform plan -out=tfplan-test; then
    echo -e "${GREEN}✅ Plan created successfully${NC}"
    rm -f tfplan-test
else
    echo -e "${RED}❌ Plan creation failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}🎉 All validations passed!${NC}"
echo ""
echo "Next steps:"
echo "1. Review terraform.tfvars"
echo "2. Run: terraform plan"
echo "3. Run: terraform apply"