#!/bin/bash
# Port Forwarding Setup for Homelab Services
# Enables external access to internal services

set -e

# Service definitions
declare -A SERVICES=(
    ["pihole"]="10.0.10.10:80:8080"      # pihole_ip:internal_port:external_port
    ["portainer"]="10.0.10.20:9000:9000"
    ["uptime-kuma"]="10.0.10.20:3001:3001"
)

echo "🔌 Setting up Port Forwarding for Homelab Services..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (on Proxmox host)"
   exit 1
fi

# Get the external interface (usually vmbr0)
get_external_interface() {
    # Find the interface with the default route
    EXTERNAL_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    echo "🌐 External interface detected: $EXTERNAL_INTERFACE"
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
    done
    
    echo "✅ Port forwarding rules configured"
}

# Save rules permanently
save_rules() {
    echo "💾 Saving firewall rules..."
    
    # Ensure iptables-persistent is installed
    if ! dpkg -l | grep -q iptables-persistent; then
        apt update
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

# Display service URLs
show_service_urls() {
    HOST_IP=$(get_host_ip)
    
    echo ""
    echo "🎉 Port Forwarding Setup Complete!"
    echo ""
    echo "🌐 External Service URLs:"
    for service in "${!SERVICES[@]}"; do
        IFS=':' read -r internal_ip internal_port external_port <<< "${SERVICES[$service]}"
        
        case $service in
            "pihole")
                echo "  📛 Pi-hole Admin: http://$HOST_IP:$external_port/admin"
                ;;
            "portainer")
                echo "  🐳 Portainer: http://$HOST_IP:$external_port"
                ;;
            "uptime-kuma")
                echo "  📊 Uptime Kuma: http://$HOST_IP:$external_port"
                ;;
            *)
                echo "  🔧 $service: http://$HOST_IP:$external_port"
                ;;
        esac
    done
    
    echo ""
    echo "📋 Internal Service URLs (from homelab network):"
    for service in "${!SERVICES[@]}"; do
        IFS=':' read -r internal_ip internal_port external_port <<< "${SERVICES[$service]}"
        
        case $service in
            "pihole")
                echo "  📛 Pi-hole Admin: http://$internal_ip/admin"
                ;;
            *)
                echo "  🔧 $service: http://$internal_ip:$internal_port"
                ;;
        esac
    done
}

# Verify port forwarding
verify_port_forwarding() {
    echo ""
    echo "🔍 Verifying port forwarding rules..."
    
    for service in "${!SERVICES[@]}"; do
        IFS=':' read -r internal_ip internal_port external_port <<< "${SERVICES[$service]}"
        
        if iptables -t nat -L PREROUTING -n | grep -q "$external_port.*$internal_ip:$internal_port"; then
            echo "  ✅ $service: Port $external_port → $internal_ip:$internal_port"
        else
            echo "  ❌ $service: Port forwarding rule missing"
        fi
    done
}

# Main execution
main() {
    get_external_interface
    setup_port_forwarding
    save_rules
    verify_port_forwarding
    show_service_urls
}

# Run main function
main "$@"
