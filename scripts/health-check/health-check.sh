#!/bin/bash
# Homelab Health Check Script
# Monitors all services and reports status

set -e

# Configuration
HOMELAB_GATEWAY="10.0.10.1"
PIHOLE_IP="10.0.10.10"
DOCKER_HOST_IP="10.0.10.20"
EXTERNAL_IP=$(ip route get 1 | awk '{print $7}' | head -1)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/var/log/homelab-health.log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to print status
print_status() {
    local service=$1
    local status=$2
    local message=$3
    
    if [ "$status" = "OK" ]; then
        echo -e "${GREEN}✅ $service:${NC} $message"
        log_message "OK - $service: $message"
    elif [ "$status" = "WARNING" ]; then
        echo -e "${YELLOW}⚠️  $service:${NC} $message"
        log_message "WARNING - $service: $message"
    else
        echo -e "${RED}❌ $service:${NC} $message"
        log_message "ERROR - $service: $message"
    fi
}

# Check network connectivity
check_network() {
    echo -e "${BLUE}🌐 Checking Network Connectivity...${NC}"
    
    # Check homelab gateway
    if ping -c 1 -W 5 "$HOMELAB_GATEWAY" > /dev/null 2>&1; then
        print_status "Gateway" "OK" "Homelab gateway ($HOMELAB_GATEWAY) is reachable"
    else
        print_status "Gateway" "ERROR" "Cannot reach homelab gateway ($HOMELAB_GATEWAY)"
    fi
    
    # Check internet connectivity
    if ping -c 1 -W 5 8.8.8.8 > /dev/null 2>&1; then
        print_status "Internet" "OK" "Internet connectivity working"
    else
        print_status "Internet" "ERROR" "No internet connectivity"
    fi
    
    # Check DNS resolution
    if nslookup google.com > /dev/null 2>&1; then
        print_status "DNS" "OK" "DNS resolution working"
    else
        print_status "DNS" "ERROR" "DNS resolution failed"
    fi
}

# Check Pi-hole service
check_pihole() {
    echo -e "${BLUE}🕳️ Checking Pi-hole Service...${NC}"
    
    # Check if Pi-hole VM is reachable
    if ping -c 1 -W 5 "$PIHOLE_IP" > /dev/null 2>&1; then
        print_status "Pi-hole VM" "OK" "Pi-hole VM ($PIHOLE_IP) is reachable"
        
        # Check Pi-hole web interface
        if curl -s -o /dev/null -w "%{http_code}" "http://$PIHOLE_IP/admin" | grep -q "200\|302"; then
            print_status "Pi-hole Web" "OK" "Pi-hole web interface is accessible"
        else
            print_status "Pi-hole Web" "ERROR" "Pi-hole web interface is not accessible"
        fi
        
        # Test DNS filtering
        if dig @"$PIHOLE_IP" doubleclick.net | grep -q "0.0.0.0\|NXDOMAIN"; then
            print_status "Pi-hole DNS" "OK" "DNS filtering is working"
        else
            print_status "Pi-hole DNS" "WARNING" "DNS filtering may not be working properly"
        fi
        
    else
        print_status "Pi-hole VM" "ERROR" "Cannot reach Pi-hole VM ($PIHOLE_IP)"
    fi
}

# Check Docker services
check_docker_services() {
    echo -e "${BLUE}🐳 Checking Docker Services...${NC}"
    
    # Check if Docker host is reachable
    if ping -c 1 -W 5 "$DOCKER_HOST_IP" > /dev/null 2>&1; then
        print_status "Docker Host" "OK" "Docker host ($DOCKER_HOST_IP) is reachable"
        
        # Check Portainer
        if curl -s -o /dev/null -w "%{http_code}" "http://$DOCKER_HOST_IP:9000" | grep -q "200\|302"; then
            print_status "Portainer" "OK" "Portainer is accessible on port 9000"
        else
            print_status "Portainer" "ERROR" "Portainer is not accessible"
        fi
        
        # Check Uptime Kuma
        if curl -s -o /dev/null -w "%{http_code}" "http://$DOCKER_HOST_IP:3001" | grep -q "200\|302"; then
            print_status "Uptime Kuma" "OK" "Uptime Kuma is accessible on port 3001"
        else
            print_status "Uptime Kuma" "ERROR" "Uptime Kuma is not accessible"
        fi
        
    else
        print_status "Docker Host" "ERROR" "Cannot reach Docker host ($DOCKER_HOST_IP)"
    fi
}

# Check external access
check_external_access() {
    echo -e "${BLUE}🌍 Checking External Access...${NC}"
    
    # Check external Portainer access
    if curl -s -o /dev/null -w "%{http_code}" "http://$EXTERNAL_IP:9000" | grep -q "200\|302"; then
        print_status "External Portainer" "OK" "Portainer accessible externally at $EXTERNAL_IP:9000"
    else
        print_status "External Portainer" "ERROR" "Portainer not accessible externally"
    fi
    
    # Check external Uptime Kuma access
    if curl -s -o /dev/null -w "%{http_code}" "http://$EXTERNAL_IP:3001" | grep -q "200\|302"; then
        print_status "External Uptime Kuma" "OK" "Uptime Kuma accessible externally at $EXTERNAL_IP:3001"
    else
        print_status "External Uptime Kuma" "ERROR" "Uptime Kuma not accessible externally"
    fi
    
    # Check external Pi-hole access
    if curl -s -o /dev/null -w "%{http_code}" "http://$EXTERNAL_IP:8080/admin" | grep -q "200\|302"; then
        print_status "External Pi-hole" "OK" "Pi-hole accessible externally at $EXTERNAL_IP:8080"
    else
        print_status "External Pi-hole" "ERROR" "Pi-hole not accessible externally"
    fi
}

# Check system resources
check_system_resources() {
    echo -e "${BLUE}💻 Checking System Resources...${NC}"
    
    # Check CPU usage
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | awk -F'%' '{print $1}')
    if (( $(echo "$CPU_USAGE < 80" | bc -l) )); then
        print_status "CPU Usage" "OK" "CPU usage is ${CPU_USAGE}%"
    else
        print_status "CPU Usage" "WARNING" "High CPU usage: ${CPU_USAGE}%"
    fi
    
    # Check memory usage
    MEM_USAGE=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
    if (( $(echo "$MEM_USAGE < 85" | bc -l) )); then
        print_status "Memory Usage" "OK" "Memory usage is ${MEM_USAGE}%"
    else
        print_status "Memory Usage" "WARNING" "High memory usage: ${MEM_USAGE}%"
    fi
    
    # Check disk usage
    DISK_USAGE=$(df -h / | awk 'NR==2 {printf "%d", $5}')
    if [ "$DISK_USAGE" -lt 85 ]; then
        print_status "Disk Usage" "OK" "Disk usage is ${DISK_USAGE}%"
    else
        print_status "Disk Usage" "WARNING" "High disk usage: ${DISK_USAGE}%"
    fi
}

# Generate summary report
generate_summary() {
    echo ""
    echo -e "${BLUE}📊 Health Check Summary${NC}"
    echo "======================================"
    echo "Check completed at: $(date)"
    echo "External IP: $EXTERNAL_IP"
    echo "Homelab Network: 10.0.10.0/24"
    echo ""
    echo "Service URLs:"
    echo "  Portainer: http://$EXTERNAL_IP:9000"
    echo "  Uptime Kuma: http://$EXTERNAL_IP:3001"
    echo "  Pi-hole: http://$EXTERNAL_IP:8080/admin"
    echo ""
    echo "Logs saved to: $LOG_FILE"
}

# Main execution
main() {
    echo -e "${BLUE}🔍 Starting Homelab Health Check...${NC}"
    echo "======================================"
    
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    
    log_message "=== Health Check Started ==="
    
    check_network
    echo ""
    check_pihole
    echo ""
    check_docker_services
    echo ""
    check_external_access
    echo ""
    check_system_resources
    
    generate_summary
    
    log_message "=== Health Check Completed ==="
}

# Run main function
main "$@"