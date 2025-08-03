#!/bin/bash
# Service health check tests for homelab services

set -e

# Service definitions
PIHOLE_IP="10.0.10.10"
DOCKER_HOST_IP="10.0.10.20"
EXTERNAL_IP=$(ip route get 1 | awk '{print $7}' | head -1)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Function to test service health
test_service_health() {
    local service_name="$1"
    local service_url="$2"
    local expected_response="$3"
    
    echo -n "Testing $service_name health... "
    
    response=$(curl -s -o /dev/null -w "%{http_code}" "$service_url" 2>/dev/null || echo "000")
    
    if echo "$response" | grep -q "$expected_response"; then
        echo -e "${GREEN}HEALTHY${NC} (HTTP $response)"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}UNHEALTHY${NC} (HTTP $response)"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Function to test Docker container status
test_docker_container() {
    local container_name="$1"
    
    echo -n "Testing Docker container $container_name... "
    
    # SSH into Docker host and check container status
    container_status=$(ssh -o ConnectTimeout=5 homelab@$DOCKER_HOST_IP "docker ps --filter name=$container_name --format '{{.Status}}'" 2>/dev/null || echo "not found")
    
    if echo "$container_status" | grep -q "Up"; then
        echo -e "${GREEN}RUNNING${NC} ($container_status)"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}NOT RUNNING${NC} ($container_status)"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Test Pi-hole service
test_pihole_service() {
    echo -e "${BLUE}🕳️ Testing Pi-hole Service Health${NC}"
    echo "=================================="
    
    # Test Pi-hole web interface
    test_service_health "Pi-hole Admin" "http://$PIHOLE_IP/admin" "200\|302"
    
    # Test Pi-hole API
    test_service_health "Pi-hole API" "http://$PIHOLE_IP/admin/api.php" "200"
    
    # Test DNS blocking functionality
    echo -n "Testing DNS blocking functionality... "
    blocked_response=$(dig @$PIHOLE_IP doubleclick.net +short 2>/dev/null || echo "error")
    if [[ "$blocked_response" == "0.0.0.0" ]] || [[ -z "$blocked_response" ]]; then
        echo -e "${GREEN}WORKING${NC} (blocked: $blocked_response)"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}NOT WORKING${NC} (not blocked: $blocked_response)"
        ((TESTS_FAILED++))
    fi
    
    echo ""
}

# Test Docker services
test_docker_services() {
    echo -e "${BLUE}🐳 Testing Docker Services Health${NC}"
    echo "=================================="
    
    # Test Docker daemon
    echo -n "Testing Docker daemon... "
    docker_status=$(ssh -o ConnectTimeout=5 homelab@$DOCKER_HOST_IP "docker info >/dev/null 2>&1 && echo 'running' || echo 'not running'" 2>/dev/null)
    if [[ "$docker_status" == "running" ]]; then
        echo -e "${GREEN}RUNNING${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}NOT RUNNING${NC}"
        ((TESTS_FAILED++))
    fi
    
    # Test individual containers
    test_docker_container "portainer"
    test_docker_container "uptime-kuma"
    
    # Test service web interfaces
    test_service_health "Portainer" "http://$DOCKER_HOST_IP:9000" "200\|302"
    test_service_health "Uptime Kuma" "http://$DOCKER_HOST_IP:3001" "200\|302"
    
    echo ""
}

# Test external access
test_external_services() {
    echo -e "${BLUE}🌍 Testing External Service Access${NC}"
    echo "==================================="
    
    if [ -n "$EXTERNAL_IP" ]; then
        test_service_health "External Portainer" "http://$EXTERNAL_IP:9000" "200\|302"
        test_service_health "External Uptime Kuma" "http://$EXTERNAL_IP:3001" "200\|302"
        test_service_health "External Pi-hole" "http://$EXTERNAL_IP:8080/admin" "200\|302"
    else
        echo -e "${YELLOW}⚠️ Could not determine external IP${NC}"
    fi
    
    echo ""
}

# Test service dependencies
test_service_dependencies() {
    echo -e "${BLUE}🔗 Testing Service Dependencies${NC}"
    echo "==============================="
    
    # Test if VMs can reach internet through gateway
    echo -n "Testing Pi-hole VM internet access... "
    pihole_internet=$(ssh -o ConnectTimeout=5 homelab@$PIHOLE_IP "ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 && echo 'ok' || echo 'fail'" 2>/dev/null)
    if [[ "$pihole_internet" == "ok" ]]; then
        echo -e "${GREEN}OK${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAILED${NC}"
        ((TESTS_FAILED++))
    fi
    
    echo -n "Testing Docker host VM internet access... "
    docker_internet=$(ssh -o ConnectTimeout=5 homelab@$DOCKER_HOST_IP "ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 && echo 'ok' || echo 'fail'" 2>/dev/null)
    if [[ "$docker_internet" == "ok" ]]; then
        echo -e "${GREEN}OK${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAILED${NC}"
        ((TESTS_FAILED++))
    fi
    
    # Test inter-VM communication
    echo -n "Testing VM-to-VM communication... "
    vm_comm=$(ssh -o ConnectTimeout=5 homelab@$PIHOLE_IP "ping -c 1 -W 5 $DOCKER_HOST_IP >/dev/null 2>&1 && echo 'ok' || echo 'fail'" 2>/dev/null)
    if [[ "$vm_comm" == "ok" ]]; then
        echo -e "${GREEN}OK${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAILED${NC}"
        ((TESTS_FAILED++))
    fi
    
    echo ""
}

# Generate health report
generate_health_report() {
    echo -e "${BLUE}📊 Service Health Summary${NC}"
    echo "========================="
    echo "Healthy Services: ${GREEN}$TESTS_PASSED${NC}"
    echo "Unhealthy Services: ${RED}$TESTS_FAILED${NC}"
    echo "Total Checks: $((TESTS_PASSED + TESTS_FAILED))"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}✅ All services are healthy!${NC}"
        echo ""
        echo "🌐 Service URLs:"
        echo "  Pi-hole: http://$EXTERNAL_IP:8080/admin"
        echo "  Portainer: http://$EXTERNAL_IP:9000"
        echo "  Uptime Kuma: http://$EXTERNAL_IP:3001"
        return 0
    else
        echo -e "${RED}❌ Some services are unhealthy. Please check the configuration.${NC}"
        echo ""
        echo "🔧 Troubleshooting suggestions:"
        echo "  1. Check if VMs are running: ssh root@proxmox 'qm list'"
        echo "  2. Check VM network config: ssh homelab@$PIHOLE_IP 'ip addr show'"
        echo "  3. Check Docker services: ssh homelab@$DOCKER_HOST_IP 'docker ps -a'"
        echo "  4. Check port forwarding: ssh root@proxmox 'iptables -t nat -L'"
        return 1
    fi
}

# Main execution
main() {
    echo -e "${BLUE}🏥 Homelab Service Health Check${NC}"
    echo "==============================="
    echo "Started at: $(date)"
    echo "External IP: $EXTERNAL_IP"
    echo ""
    
    # Check required tools
    if ! command -v ssh &> /dev/null; then
        echo -e "${RED}❌ SSH client is required for service health checks${NC}"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}❌ curl is required for HTTP health checks${NC}"
        exit 1
    fi
    
    # Run health checks
    test_pihole_service
    test_docker_services
    test_external_services
    test_service_dependencies
    
    # Generate report
    generate_health_report
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi