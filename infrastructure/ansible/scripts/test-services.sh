#!/bin/bash
# Test deployed services

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🧪 Testing Deployed Services${NC}"
echo "============================"

cd "$ANSIBLE_DIR"

# Get host IPs from inventory
PIHOLE_IP=$(ansible-inventory --list | jq -r '.pihole.hosts["pihole-tf"]' 2>/dev/null || echo "10.0.10.11")
DOCKER_IP=$(ansible-inventory --list | jq -r '.docker_hosts.hosts["docker-host-tf"]' 2>/dev/null || echo "10.0.10.21")

echo "Testing services on:"
echo "  Pi-hole: $PIHOLE_IP"
echo "  Docker:  $DOCKER_IP"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

# Test function
test_service() {
    local name="$1"
    local url="$2"
    local expected="$3"
    
    echo -n "Testing $name... "
    
    if response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url" 2>/dev/null); then
        if [[ "$response" =~ $expected ]]; then
            echo -e "${GREEN}OK${NC} (HTTP $response)"
            ((TESTS_PASSED++))
            return 0
        else
            echo -e "${RED}FAILED${NC} (HTTP $response, expected $expected)"
            ((TESTS_FAILED++))
            return 1
        fi
    else
        echo -e "${RED}FAILED${NC} (Connection error)"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Test DNS function
test_dns() {
    local server="$1"
    local domain="$2"
    local expected="$3"
    
    echo -n "Testing DNS ($domain via $server)... "
    
    if result=$(dig @"$server" "$domain" +short +time=5 2>/dev/null); then
        if [[ "$result" =~ $expected ]]; then
            echo -e "${GREEN}OK${NC} ($result)"
            ((TESTS_PASSED++))
            return 0
        else
            echo -e "${RED}FAILED${NC} (got: $result, expected: $expected)"
            ((TESTS_FAILED++))
            return 1
        fi
    else
        echo -e "${RED}FAILED${NC} (DNS query failed)"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Test Pi-hole services
echo -e "${BLUE}🕳️  Testing Pi-hole Services${NC}"
test_service "Pi-hole Admin" "http://$PIHOLE_IP/admin" "200|302"
test_service "Pi-hole API" "http://$PIHOLE_IP/admin/api.php" "200"

# Test DNS resolution
test_dns "$PIHOLE_IP" "google.com" "[0-9]"
test_dns "$PIHOLE_IP" "doubleclick.net" "0\.0\.0\.0|^$"

echo ""

# Test Docker services
echo -e "${BLUE}🐳 Testing Docker Services${NC}"
test_service "Portainer" "http://$DOCKER_IP:9000" "200|302"
test_service "Uptime Kuma" "http://$DOCKER_IP:3001" "200|302"

echo ""

# Test SSH connectivity
echo -e "${BLUE}🔐 Testing SSH Access${NC}"
for host in pihole docker_hosts; do
    echo -n "Testing SSH to $host... "
    if ansible "$host" -m ping --one-line > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAILED${NC}"
        ((TESTS_FAILED++))
    fi
done

echo ""

# Summary
echo -e "${BLUE}📊 Test Results${NC}"
echo "==============="
echo "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo "Failed: ${RED}$TESTS_FAILED${NC}"
echo "Total:  $((TESTS_PASSED + TESTS_FAILED))"

if [ $TESTS_FAILED -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 All services are working correctly!${NC}"
    echo ""
    echo "Service URLs:"
    echo "  Pi-hole Admin: http://$PIHOLE_IP/admin"
    echo "  Portainer: http://$DOCKER_IP:9000"
    echo "  Uptime Kuma: http://$DOCKER_IP:3001"
    exit 0
else
    echo ""
    echo -e "${RED}❌ Some services failed. Please check the configuration.${NC}"
    exit 1
fi