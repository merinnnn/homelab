#!/bin/bash
# Port Forwarding Setup for Homelab Services
# Enables external access to internal services

set -e

# Service definitions
declare -A SERVICES=(
    # Core services
    ["pihole"]="10.0.10.10:80:8080"      # pihole_ip:internal_port:external_port
    ["portainer"]="10.0.10.20:9000:9000"
    ["uptime-kuma"]="10.0.10.20:3001:3001"

    # Monitoring services
    ["grafana"]="10.0.10.20:3000:3000"               # Monitoring dashboard
    ["prometheus"]="10.0.10.20:9090:9090"            # Metrics database
    ["cadvisor"]="10.0.10.20:8081:8081"              # Container metrics
    ["alertmanager"]="10.0.10.20:9093:9093"          # Alert management
    ["node-exporter"]="10.0.10.20:9100:9100"         # System metrics
    ["pihole-exporter"]="10.0.10.20:9617:9617"       # Pi-hole metrics
    ["blackbox-exporter"]="10.0.10.20:9115:9115"     # Service health checks
)

echo "🔌 Setting up Port Forwarding for Homelab Services..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (on Proxmox host)"
   echo "Usage: ssh root@proxmox-host 'bash -s' < setup-port-forwarding.sh"
   exit 1
fi

# Get the external interface (usually vmbr0)
get_external_interface() {
    # Find the interface with the default route
    EXTERNAL_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -z "$EXTERNAL_INTERFACE" ]; then
        echo "❌ Could not determine external interface"
        exit 1
    fi
    echo "🌐 External interface detected: $EXTERNAL_INTERFACE"
}

# Clean existing homelab port forwarding rules
clean_existing_rules() {
    echo "🧹 Cleaning existing homelab port forwarding rules..."
    
    # Remove existing DNAT rules for homelab services
    iptables -t nat -S PREROUTING | grep "10.0.10" | grep "DNAT" | while read -r rule; do
        # Convert -S output to -D format
        delete_rule=$(echo "$rule" | sed 's/^-A PREROUTING/-D PREROUTING/')
        echo "  Removing: $delete_rule"
        iptables -t nat $delete_rule 2>/dev/null || true
    done
    
    # Remove existing FORWARD rules for homelab services
    iptables -S FORWARD | grep "10.0.10" | grep "ACCEPT" | while read -r rule; do
        delete_rule=$(echo "$rule" | sed 's/^-A FORWARD/-D FORWARD/')
        echo "  Removing: $delete_rule"
        iptables $delete_rule 2>/dev/null || true
    done
    
    echo "✅ Cleanup completed"
}

# Set up port forwarding rules
setup_port_forwarding() {
    echo "🔀 Setting up port forwarding rules..."
    
    for service in "${!SERVICES[@]}"; do
        IFS=':' read -r internal_ip internal_port external_port <<< "${SERVICES[$service]}"
        
        echo "  Setting up $service: $internal_ip:$internal_port → *:$external_port"
        
        # Add DNAT rule for incoming traffic
        iptables -t nat -A PREROUTING -i "$EXTERNAL_INTERFACE" -p tcp --dport "$external_port" -j DNAT --to "$internal_ip:$internal_port"
        
        # Allow forwarded traffic
        iptables -A FORWARD -d "$internal_ip" -p tcp --dport "$internal_port" -j ACCEPT
        iptables -A FORWARD -s "$internal_ip" -p tcp --sport "$internal_port" -j ACCEPT
    done
    
    # Add general homelab network forwarding rules (if not already present)
    if ! iptables -C FORWARD -s 10.0.10.0/24 -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -s 10.0.10.0/24 -j ACCEPT
    fi
    
    if ! iptables -C FORWARD -d 10.0.10.0/24 -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -d 10.0.10.0/24 -j ACCEPT
    fi
    
    echo "✅ Port forwarding rules configured"
}

# Save rules permanently
save_rules() {
    echo "💾 Saving firewall rules..."
    
    # Ensure iptables-persistent is installed
    if ! dpkg -l | grep -q iptables-persistent; then
        echo "  Installing iptables-persistent..."
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
    fi
    
    # Save current rules
    iptables-save > /etc/iptables/rules.v4
    
    echo "✅ Rules saved permanently"
}

# Get host IP for display
get_host_ip() {
    HOST_IP=$(ip route get 1 | awk '{print $7}' | head -1)
    echo "$HOST_IP"
}

# Display service URLs with categories
show_service_urls() {
    HOST_IP=$(get_host_ip)
    
    echo ""
    echo "🎉 Port Forwarding Setup Complete!"
    echo ""
    echo "🌐 External Service URLs (Access from anywhere):"
    echo "================================================"
    
    echo ""
    echo "📊 MONITORING & OBSERVABILITY:"
    echo "  🔍 Grafana Dashboard:    http://$HOST_IP:3000"
    echo "  📈 Prometheus:           http://$HOST_IP:9090"
    echo "  🚨 Alertmanager:         http://$HOST_IP:9093"
    echo "  📦 cAdvisor:             http://$HOST_IP:8081"
    echo "  💻 Node Exporter:        http://$HOST_IP:9100/metrics"
    echo "  🕳️  Pi-hole Exporter:     http://$HOST_IP:9617/metrics"
    echo "  🔍 Blackbox Exporter:    http://$HOST_IP:9115"
    
    echo ""
    echo "🔧 INFRASTRUCTURE MANAGEMENT:"
    echo "  🕳️  Pi-hole Admin:        http://$HOST_IP:8080/admin"
    echo "  🐳 Portainer:            http://$HOST_IP:9000"
    echo "  📊 Uptime Kuma:          http://$HOST_IP:3001"
    
    echo ""
    echo "🏠 Internal Service URLs (From homelab network only):"
    echo "====================================================="
    
    echo ""
    echo "📊 MONITORING:"
    echo "  🔍 Grafana:              http://10.0.10.20:3000"
    echo "  📈 Prometheus:           http://10.0.10.20:9090"
    echo "  🚨 Alertmanager:         http://10.0.10.20:9093"
    
    echo ""
    echo "🔧 SERVICES:"
    echo "  🕳️  Pi-hole Admin:        http://10.0.10.10/admin"
    echo "  🐳 Portainer:            http://10.0.10.20:9000"
    echo "  📊 Uptime Kuma:          http://10.0.10.20:3001"
    
    echo ""
    echo "🔑 DEFAULT CREDENTIALS:"
    echo "======================"
    echo "  Grafana:    admin / changeThisPassword123!"
    echo "  Portainer:  Set up on first access"
    echo "  Pi-hole:    Set up during installation"
    
    echo ""
    echo "💡 QUICK START TIPS:"
    echo "==================="
    echo "  • Access Grafana and import these dashboards:"
    echo "    - 1860 (Node Exporter Full)"
    echo "    - 193 (Docker Container Monitoring)"
    echo "    - 10176 (Pi-hole Exporter)"
    echo "  • Check Prometheus targets: http://$HOST_IP:9090/targets"
    echo "  • Monitor alerts: http://$HOST_IP:9093/#/alerts"
    echo "  • Run health check: ~/homelab/monitoring/health-check.sh"
}

# Verify port forwarding
verify_port_forwarding() {
    echo ""
    echo "🔍 Verifying port forwarding rules..."
    
    # Check DNAT rules
    echo ""
    echo "DNAT Rules (Port Forwarding):"
    echo "============================"
    
    local rules_ok=true
    for service in "${!SERVICES[@]}"; do
        IFS=':' read -r internal_ip internal_port external_port <<< "${SERVICES[$service]}"
        
        if iptables -t nat -L PREROUTING -n | grep -q "$external_port.*$internal_ip:$internal_port"; then
            echo "  ✅ $service: Port $external_port → $internal_ip:$internal_port"
        else
            echo "  ❌ $service: Port forwarding rule missing"
            rules_ok=false
        fi
    done
    
    # Check FORWARD rules
    echo ""
    echo "FORWARD Rules (Traffic Allowing):"
    echo "================================="
    
    if iptables -L FORWARD -n | grep -q "ACCEPT.*10.0.10.0/24"; then
        echo "  ✅ Homelab network forwarding enabled"
    else
        echo "  ❌ Homelab network forwarding rules missing"
        rules_ok=false
    fi
    
    # Check NAT rules for internet access
    echo ""
    echo "NAT Rules (Internet Access):"
    echo "============================"
    
    if iptables -t nat -L POSTROUTING -n | grep -q "MASQUERADE.*10.0.10.0/24"; then
        echo "  ✅ NAT rule for homelab internet access"
    else
        echo "  ⚠️  NAT rule may be missing - check internet access from VMs"
    fi
    
    if [ "$rules_ok" = true ]; then
        echo ""
        echo "✅ All port forwarding rules verified successfully"
    else
        echo ""
        echo "❌ Some port forwarding rules are missing - re-run the script"
        return 1
    fi
}

# Test connectivity to services
test_service_connectivity() {
    echo ""
    echo "🔍 Testing Service Connectivity..."
    echo "================================="
    
    HOST_IP=$(get_host_ip)
    local services_to_test=(
        "Grafana:$HOST_IP:3000"
        "Prometheus:$HOST_IP:9090"
        "Pi-hole:$HOST_IP:8080"
        "Portainer:$HOST_IP:9000"
    )
    
    for service_info in "${services_to_test[@]}"; do
        IFS=':' read -r service_name host port <<< "$service_info"
        
        echo -n "  Testing $service_name ($host:$port)... "
        
        if timeout 5 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
            echo "✅ Reachable"
        else
            echo "❌ Not reachable"
        fi
    done
}

# Generate firewall summary
generate_firewall_summary() {
    echo ""
    echo "🧱 Firewall Configuration Summary:"
    echo "=================================="
    
    echo ""
    echo "Active DNAT Rules:"
    iptables -t nat -L PREROUTING -n --line-numbers | grep "10.0.10" | head -10
    
    echo ""
    echo "Active FORWARD Rules:"
    iptables -L FORWARD -n --line-numbers | grep "10.0.10" | head -5
    
    echo ""
    echo "Port Usage Summary:"
    echo "=================="
    echo "  Core Services:    8080, 9000, 3001"
    echo "  Monitoring:       3000, 9090, 9093, 8081"
    echo "  Exporters:        9100, 9115, 9617"
    echo "  Reserved:         22 (SSH), 53 (DNS), 80 (HTTP)"
}

# Backup current iptables rules
backup_iptables_rules() {
    local backup_dir="/root/homelab-backups"
    local backup_file="$backup_dir/iptables-backup-$(date +%Y%m%d_%H%M%S).rules"
    
    mkdir -p "$backup_dir"
    iptables-save > "$backup_file"
    echo "📋 Current iptables rules backed up to: $backup_file"
}

# Main execution
main() {
    echo "Starting homelab port forwarding setup..."
    echo "External interface will be auto-detected"
    echo ""
    
    # Create backup before making changes
    backup_iptables_rules
    
    # Execute setup steps
    get_external_interface
    clean_existing_rules
    setup_port_forwarding
    save_rules
    
    # Verification and display
    verify_port_forwarding
    test_service_connectivity
    show_service_urls
    generate_firewall_summary
    
    echo ""
    echo "🔧 Management Commands:"
    echo "======================"
    echo "  View all rules:      iptables -t nat -L -n"
    echo "  Check connectivity:  ~/homelab/monitoring/health-check.sh"
    echo "  Restart services:    docker-compose restart"
    echo "  View logs:          docker-compose logs -f"
    
    echo ""
    echo "📝 Next Steps:"
    echo "=============="
    echo "  1. Access Grafana at http://$(get_host_ip):3000"
    echo "  2. Import recommended dashboards"
    echo "  3. Configure alerting in Alertmanager"
    echo "  4. Set up automated backups"
    echo "  5. Run regular health checks"
}

# Handle script arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verify-only)
            echo "🔍 Running verification only..."
            get_external_interface
            verify_port_forwarding
            test_service_connectivity
            exit 0
            ;;
        --show-urls)
            show_service_urls
            exit 0
            ;;
        --backup-only)
            backup_iptables_rules
            exit 0
            ;;
        -h|--help)
            echo "Homelab Port Forwarding Setup"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verify-only    Only verify existing rules"
            echo "  --show-urls      Display service URLs"
            echo "  --backup-only    Backup current iptables rules"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                    # Full setup"
            echo "  $0 --verify-only      # Check existing rules"
            echo "  $0 --show-urls        # Show service URLs"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main "$@"
