#!/bin/bash
# Proxmox Homelab Network Setup Script
# Sets up isolated homelab network with internet access

set -e

HOMELAB_NETWORK="10.0.10.0/24"
HOMELAB_GATEWAY="10.0.10.1"
BRIDGE_NAME="vmbr1"

echo "🌐 Setting up Homelab Network Infrastructure..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (on Proxmox host)"
   echo "Usage: ssh root@proxmox-ip 'bash -s' < setup-homelab-network.sh"
   exit 1
fi

# Backup current network configuration
backup_network_config() {
    echo "📋 Backing up current network configuration..."
    cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)
    echo "✓ Network configuration backed up"
}

# Create homelab bridge configuration
setup_bridge_config() {
    echo "🌉 Setting up bridge configuration..."
    
    # Check if vmbr1 already exists
    if grep -q "auto $BRIDGE_NAME" /etc/network/interfaces; then
        echo "⚠️  Bridge $BRIDGE_NAME already exists in configuration"
        return 0
    fi
    
    # Add bridge configuration
    cat >> /etc/network/interfaces << EOF

# Homelab internal network
auto $BRIDGE_NAME
iface $BRIDGE_NAME inet static
        address $HOMELAB_GATEWAY/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up iptables -t nat -A POSTROUTING -s '$HOMELAB_NETWORK' -o vmbr0 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s '$HOMELAB_NETWORK' -o vmbr0 -j MASQUERADE
EOF
    
    echo "✓ Bridge configuration added to /etc/network/interfaces"
}

# Enable IP forwarding
enable_ip_forwarding() {
    echo "🔄 Enabling IP forwarding..."
    
    # Enable immediately
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # Make permanent
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi
    
    echo "✓ IP forwarding enabled"
}

# Set up NAT and firewall rules
setup_firewall_rules() {
    echo "🔥 Setting up firewall rules..."
    
    # Add NAT rule for internet access
    iptables -t nat -A POSTROUTING -s "$HOMELAB_NETWORK" -o vmbr0 -j MASQUERADE
    
    # Allow forwarding for homelab network
    iptables -A FORWARD -s "$HOMELAB_NETWORK" -j ACCEPT
    iptables -A FORWARD -d "$HOMELAB_NETWORK" -j ACCEPT
    
    echo "✓ Firewall rules configured"
}

# Install and configure iptables-persistent
setup_persistent_rules() {
    echo "💾 Making firewall rules persistent..."
    
    # Install iptables-persistent if not already installed
    if ! dpkg -l | grep -q iptables-persistent; then
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
    fi
    
    # Save current rules
    iptables-save > /etc/iptables/rules.v4
    
    echo "✓ Firewall rules saved persistently"
}

# Start the bridge interface
start_bridge() {
    echo "🚀 Starting bridge interface..."
    
    # Restart networking
    systemctl restart networking
    
    # Bring up the bridge
    ifup $BRIDGE_NAME
    
    echo "✓ Bridge interface started"
}

# Restart Proxmox web services
restart_proxmox_services() {
    echo "🔄 Restarting Proxmox web services..."
    
    systemctl restart pveproxy
    systemctl restart pvedaemon
    
    echo "✓ Proxmox services restarted"
    echo "ℹ️  Please wait 30 seconds and refresh your browser (Ctrl+F5)"
}

# Verify network setup
verify_setup() {
    echo "🔍 Verifying network setup..."
    
    # Check if bridge exists and has correct IP
    if ip addr show $BRIDGE_NAME | grep -q "$HOMELAB_GATEWAY/24"; then
        echo "✅ Bridge $BRIDGE_NAME is up with IP $HOMELAB_GATEWAY/24"
    else
        echo "❌ Bridge $BRIDGE_NAME setup failed"
        return 1
    fi
    
    # Check IP forwarding
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        echo "✅ IP forwarding is enabled"
    else
        echo "❌ IP forwarding is not enabled"
        return 1
    fi
    
    # Check NAT rules
    if iptables -t nat -L POSTROUTING -n | grep -q "$HOMELAB_NETWORK"; then
        echo "✅ NAT rules are configured"
    else
        echo "❌ NAT rules are missing"
        return 1
    fi
    
    echo "✅ Network setup verification complete"
}

# Display summary
show_summary() {
    echo ""
    echo "🎉 Homelab Network Setup Complete!"
    echo ""
    echo "📊 Network Configuration Summary:"
    echo "  Bridge Name: $BRIDGE_NAME"
    echo "  Network Range: $HOMELAB_NETWORK"
    echo "  Gateway IP: $HOMELAB_GATEWAY"
    echo "  Internet Access: ✅ Enabled via NAT"
    echo ""
    echo "📋 Next Steps:"
    echo "1. Create VMs using $BRIDGE_NAME as network interface"
    echo "2. Assign static IPs in range 10.0.10.10-10.0.10.250"
    echo "3. Use $HOMELAB_GATEWAY as gateway in VM network config"
    echo "4. Use 8.8.8.8,1.1.1.1 as DNS servers in VMs"
    echo ""
    echo "🔧 VM Network Configuration Example:"
    echo "  IP: 10.0.10.10 (for Pi-hole)"
    echo "  Netmask: 255.255.255.0 (/24)"
    echo "  Gateway: $HOMELAB_GATEWAY"
    echo "  DNS: 8.8.8.8,1.1.1.1"
}

# Main execution
main() {
    echo "Starting Proxmox homelab network setup..."
    echo ""
    
    backup_network_config
    setup_bridge_config
    enable_ip_forwarding
    setup_firewall_rules
    setup_persistent_rules
    start_bridge
    restart_proxmox_services
    
    sleep 5
    verify_setup
    show_summary
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi