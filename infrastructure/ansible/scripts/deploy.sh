#!/bin/bash
# Ansible deployment script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "$ANSIBLE_DIR"

echo -e "${BLUE}🚀 Homelab Ansible Deployment${NC}"
echo "============================="

# Parse command line arguments
PLAYBOOK="site.yml"
TAGS=""
LIMIT=""
CHECK_MODE=""
VERBOSE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--playbook)
            PLAYBOOK="$2"
            shift 2
            ;;
        -t|--tags)
            TAGS="--tags $2"
            shift 2
            ;;
        -l|--limit)
            LIMIT="--limit $2"
            shift 2
            ;;
        -c|--check)
            CHECK_MODE="--check"
            shift
            ;;
        -v|--verbose)
            VERBOSE="-v"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -p, --playbook PLAYBOOK  Playbook to run (default: site.yml)"
            echo "  -t, --tags TAGS          Run only tasks with these tags"
            echo "  -l, --limit HOSTS        Limit to specific hosts"
            echo "  -c, --check              Run in check mode (dry run)"
            echo "  -v, --verbose            Verbose output"
            echo "  -h, --help               Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                       # Run full deployment"
            echo "  $0 -p pihole-only.yml   # Deploy only Pi-hole"
            echo "  $0 -l docker_hosts      # Deploy only to Docker hosts"
            echo "  $0 -c                    # Dry run"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate before deployment
echo -e "${BLUE}🔍 Running pre-deployment validation...${NC}"
if ! ./scripts/validate.sh > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Validation issues found. Continuing anyway...${NC}"
fi

# Test connectivity
echo -e "${BLUE}🌐 Testing host connectivity...${NC}"
if ansible all -m ping --one-line $LIMIT; then
    echo -e "${GREEN}✅ All target hosts reachable${NC}"
else
    echo -e "${RED}❌ Some hosts unreachable${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Show deployment plan
echo ""
echo -e "${BLUE}📋 Deployment Plan:${NC}"
echo "  Playbook: playbooks/$PLAYBOOK"
[[ -n "$TAGS" ]] && echo "  Tags: $TAGS"
[[ -n "$LIMIT" ]] && echo "  Hosts: $LIMIT"
[[ -n "$CHECK_MODE" ]] && echo "  Mode: Check (dry run)"

echo ""
if [[ -z "$CHECK_MODE" ]]; then
    read -p "Continue with deployment? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
fi

# Run playbook
echo -e "${BLUE}🎯 Running Ansible playbook...${NC}"
if ansible-playbook "playbooks/$PLAYBOOK" $TAGS $LIMIT $CHECK_MODE $VERBOSE; then
    echo -e "${GREEN}🎉 Deployment completed successfully!${NC}"
else
    echo -e "${RED}❌ Deployment failed${NC}"
    exit 1
fi

# Post-deployment validation
if [[ -z "$CHECK_MODE" ]]; then
    echo ""
    echo -e "${BLUE}🔍 Running post-deployment validation...${NC}"
    ./scripts/test-services.sh
fi