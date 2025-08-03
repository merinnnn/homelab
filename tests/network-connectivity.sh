# Network connectivity tests for homelab infrastructure

set -e

# Test configuration
HOMELAB_GATEWAY="10.0.10.1"
PIHOLE_IP="10.0.10.10"
DOCKER_HOST_IP="10.0.10.20"
DNS_SERVERS=("8.8.8.8" "1.1.1.1")
TEST_DOMAINS=("google.com" "github.com" "docker.com")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Function to run test and report result
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="$3"
    
    echo -n "Testing $test_name... "
    
    if eval "$test_command" > /dev/null 2>&1; then
        if [ "$expected_result" = "pass" ] || [ -z "$expected_result" ]; then
            echo -e "${GREEN}PASS${NC}"
            ((TESTS_PASSED++))
            return 0
        else
            echo -e "${RED}FAIL${NC} (unexpected success)"
            ((TESTS_FAILED++))
            return 1
        fi
    else
        if [ "$expected_result" = "fail" ]; then
            echo -e "${GREEN}PASS${NC} (expected failure)"
            ((TESTS_PASSED++))
            return 0
        else
            echo -e "${RED}FAIL${NC}"
            ((TESTS_FAILED++))
            return 1
        fi
    fi
}

# Test basic network connectivity
test_basic_connectivity() {
    echo -e "${BLUE}🌐 Testing Basic Network Connectivity${NC}"
    echo "========================================="
    
    # Test loopback
    run_test "Loopback interface" "ping -c 1 -W 2 127.0.0.1"
    
    # Test homelab gateway
    run_test "Homelab gateway ($HOMELAB_GATEWAY)" "ping -c 1 -W 5 $HOMELAB_GATEWAY"
    
    # Test internet connectivity
    run_test "Internet connectivity (8.8.8.8)" "ping -c 1 -W 5 8.8.8.8"
    
    # Test Pi-hole VM
    run_test "Pi-hole VM ($PIHOLE_IP)" "ping -c 1 -W 5 $PIHOLE_IP"
    
    # Test Docker host VM
    run_test "Docker host VM ($DOCKER_HOST_IP)" "ping -c 1 -W 5 $DOCKER_HOST_IP"
    
    echo ""
}

# Test DNS resolution
test_dns_resolution() {
    echo -e "${BLUE}🔍 Testing DNS Resolution${NC}"
    echo "=========================="
    
    # Test DNS servers
    for dns_server in "${DNS_SERVERS[@]}"; do
        run_test "DNS server $dns_server" "nslookup google.com $dns_server"
    done
    
    # Test domain resolution
    for domain in "${TEST_DOMAINS[@]}"; do
        run_test "Domain resolution ($domain)" "nslookup $domain"
    done
    
    # Test reverse DNS
    run_test "Reverse DNS (8.8.8.8)" "nslookup 8.8.8.8"
    
    echo ""
}

# Test port connectivity
test_port_connectivity() {
    echo -e "${BLUE}🔌 Testing Port Connectivity${NC}"
    echo "============================="
    
    # Test Pi-hole HTTP
    run_test "Pi-hole HTTP (port 80)" "nc -z -w5 $PIHOLE_IP 80"
    
    # Test Pi-hole DNS TCP
    run_test "Pi-hole DNS TCP (port 53)" "nc -z -w5 $PIHOLE_IP 53"
    
    # Test Pi-hole DNS UDP
    run_test "Pi-hole DNS UDP (port 53)" "nc -u -z -w5 $PIHOLE_IP 53"
    
    # Test Portainer
    run_test "Portainer (port 9000)" "nc -z -w5 $DOCKER_HOST_IP 9000"
    
    # Test Uptime Kuma
    run_test "Uptime Kuma (port 3001)" "nc -z -w5 $DOCKER_HOST_IP 3001"
    
    echo ""
}

# Test HTTP services
test_http_services() {
    echo -e "${BLUE}🌐 Testing HTTP Services${NC}"
    echo "========================"
    
    # Test Pi-hole web interface
    run_test "Pi-hole web interface" "curl -s -o /dev/null -w '%{http_code}' http://$PIHOLE_IP/admin | grep -q '200\|302'"
    
    # Test Portainer web interface
    run_test "Portainer web interface" "curl -s -o /dev/null -w '%{http_code}' http://$DOCKER_HOST_IP:9000 | grep -q '200\|302'"
    
    # Test Uptime Kuma web interface
    run_test "Uptime Kuma web interface" "curl -s -o /dev/null -w '%{http_code}' http://$DOCKER_HOST_IP:3001 | grep -q '200\|302'"
    
    echo ""
}

# Test DNS filtering (Pi-hole specific)
test_dns_filtering() {
    echo -e "${BLUE}🛡️ Testing DNS Filtering${NC}"
    echo "========================"
    
    # Test blocked domain (should be blocked by Pi-hole)
    run_test "Ad domain blocking" "dig @$PIHOLE_IP doubleclick.net | grep -q '0.0.0.0\|NXDOMAIN'"
    
    # Test allowed domain (should resolve normally)
    run_test "Normal domain resolution" "dig @$PIHOLE_IP google.com | grep -q 'ANSWER: [1-9]'"
    
    echo ""
}

# Test external access (port forwarding)
test_external_access() {
    echo -e "${BLUE}🌍 Testing External Access${NC}"
    echo "=========================="
    
    # Get external IP
    EXTERNAL_IP=$(ip route get 1 | awk '{print $7}' | head -1)
    
    if [ -n "$EXTERNAL_IP" ]; then
        echo "Testing external access via $EXTERNAL_IP..."
        
        # Test external Portainer access
        run_test "External Portainer (port 9000)" "curl -s -o /dev/null -w '%{http_code}' http://$EXTERNAL_IP:9000 | grep -q '200\|302'"
        
        # Test external Uptime Kuma access
        run_test "External Uptime Kuma (port 3001)" "curl -s -o /dev/null -w '%{http_code}' http://$EXTERNAL_IP:3001 | grep -q '200\|302'"
        
        # Test external Pi-hole access
        run_test "External Pi-hole (port 8080)" "curl -s -o /dev/null -w '%{http_code}' http://$EXTERNAL_IP:8080/admin | grep -q '200\|302'"
    else
        echo -e "${YELLOW}⚠️ Could not determine external IP, skipping external access tests${NC}"
    fi
    
    echo ""
}

# Generate test report
generate_test_report() {
    echo -e "${BLUE}📊 Test Results Summary${NC}"
    echo "======================="
    echo "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo "Tests Failed: ${RED}$TESTS_FAILED${NC}"
    echo "Total Tests: $((TESTS_PASSED + TESTS_FAILED))"
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}✅ All tests passed! Homelab network is working correctly.${NC}"
        return 0
    else
        echo -e "${RED}❌ Some tests failed. Please check the network configuration.${NC}"
        return 1
    fi
}

# Main execution
main() {
    echo -e "${BLUE}🧪 Homelab Network Connectivity Tests${NC}"
    echo "======================================"
    echo "Started at: $(date)"
    echo ""
    
    # Check if required tools are installed
    required_tools=("ping" "nslookup" "nc" "curl" "dig")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo -e "${RED}❌ Required tool '$tool' is not installed${NC}"
            echo "Please install it with: sudo apt install dnsutils netcat-openbsd curl"
            exit 1
        fi
    done
    
    # Run test suites
    test_basic_connectivity
    test_dns_resolution
    test_port_connectivity
    test_http_services
    test_dns_filtering
    test_external_access
    
    # Generate final report
    echo ""
    generate_test_report
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi