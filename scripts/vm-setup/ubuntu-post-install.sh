#!/bin/bash
# Ubuntu VM Post-Installation Setup Script
# Configures Ubuntu VMs for homelab use

set -e

VM_TYPE=""
VM_IP=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --type)
            VM_TYPE="$2"
            shift 2
            ;;
        --ip)
            VM_IP="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --type [pihole|docker] --ip [VM_IP]"
            echo "Example: $0 --type docker --ip 10.0.10.20"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate arguments
if [[ -z "$VM_TYPE" || -z "$VM_IP" ]]; then
    echo "❌ Missing required arguments"
    echo "Usage: $0 --type [pihole|docker] --ip [VM_IP]"
    exit 1
fi

echo "🚀 Starting Ubuntu post-installation setup for $VM_TYPE VM..."

# Update system packages
update_system() {
    echo "📦 Updating system packages..."
    sudo apt update
    sudo apt upgrade -y
    echo "✅ System updated"
}

# Install common packages
install_common_packages() {
    echo "📚 Installing common packages..."
    sudo apt install -y \
        curl \
        wget \
        git \
        htop \
        nano \
        vim \
        unzip \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        net-tools \
        dnsutils
    echo "✅ Common packages installed"
}

# Configure SSH (harden)
configure_ssh() {
    echo "🔐 Configuring SSH security..."
    
    # Backup original config
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # Apply security settings
    sudo sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    
    # Restart SSH service
    sudo systemctl restart ssh
    
    echo "✅ SSH configured"
}

# Set up automatic updates
setup_auto_updates() {
    echo "🔄 Setting up automatic security updates..."
    
    sudo apt install -y unattended-upgrades
    
    # Configure automatic updates
    echo 'Unattended-Upgrade::Automatic-Reboot "false";' | sudo tee -a /etc/apt/apt.conf.d/50unattended-upgrades
    
    # Enable automatic updates
    sudo dpkg-reconfigure -plow unattended-upgrades
    
    echo "✅ Automatic updates configured"
}

# Install Docker (for docker-host VM)
install_docker() {
    if [[ "$VM_TYPE" != "docker" ]]; then
        return 0
    fi
    
    echo "🐳 Installing Docker..."
    
    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Set up the repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Add user to docker group
    sudo usermod -aG docker $USER
    
    # Install docker-compose
    sudo apt install -y docker-compose
    
    # Enable Docker service
    sudo systemctl enable docker
    sudo systemctl start docker
    
    echo "✅ Docker installed"
}

# Install Pi-hole prerequisites (for pihole VM)
install_pihole_prereqs() {
    if [[ "$VM_TYPE" != "pihole" ]]; then
        return 0
    fi
    
    echo "🕳️ Installing Pi-hole prerequisites..."
    
    # Install required packages for Pi-hole
    sudo apt install -y \
        lighttpd \
        php-common \
        php-cgi \
        php-sqlite3 \
        sqlite3
    
    echo "✅ Pi-hole prerequisites installed"
}

# Configure timezone
configure_timezone() {
    echo "🕒 Configuring timezone..."
    sudo timedatectl set-timezone Europe/London
    echo "✅ Timezone set to Europe/London"
}

# Set up firewall (basic UFW configuration)
setup_firewall() {
    echo "🔥 Setting up basic firewall..."
    
    # Install UFW if not present
    sudo apt install -y ufw
    
    # Reset UFW to defaults
    sudo ufw --force reset
    
    # Default policies
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # Allow SSH
    sudo ufw allow ssh
    
    # Allow specific ports based on VM type
    case $VM_TYPE in
        "pihole")
            sudo ufw allow 80/tcp   # HTTP
            sudo ufw allow 53/tcp   # DNS TCP
            sudo ufw allow 53/udp   # DNS UDP
            ;;
        "docker")
            sudo ufw allow 9000/tcp  # Portainer
            sudo ufw allow 3001/tcp  # Uptime Kuma
            ;;
    esac
    
    # Enable UFW
    sudo ufw --force enable
    
    echo "✅ Firewall configured"
}

# Create homelab user directory structure
setup_user_directories() {
    echo "📁 Setting up user directories..."
    
    mkdir -p ~/homelab/{configs,scripts,logs,backups}
    
    case $VM_TYPE in
        "docker")
            mkdir -p ~/homelab/{portainer,uptime-kuma,future-services}
            ;;
        "pihole")
            mkdir -p ~/homelab/pihole-config
            ;;
    esac
    
    echo "✅ User directories created"
}

# Display completion summary
show_completion_summary() {
    echo ""
    echo "🎉 Ubuntu VM Post-Installation Complete!"
    echo ""
    echo "📊 VM Configuration Summary:"
    echo "  VM Type: $VM_TYPE"
    echo "  VM IP: $VM_IP"
    echo "  Timezone: $(timedatectl show --property=Timezone --value)"
    echo "  SSH: Secured (root login disabled)"
    echo "  Firewall: Enabled with service-specific rules"
    echo "  Auto Updates: Enabled for security packages"
    
    if [[ "$VM_TYPE" == "docker" ]]; then
        echo "  Docker: Installed and enabled"
        echo "  Docker Compose: Installed"
    fi
    
    if [[ "$VM_TYPE" == "pihole" ]]; then
        echo "  Pi-hole Prerequisites: Installed"
    fi
    
    echo ""
    echo "📋 Next Steps:"
    case $VM_TYPE in
        "docker")
            echo "1. Reboot to apply Docker group membership: sudo reboot"
            echo "2. Deploy services with docker-compose"
            echo "3. Configure external access via port forwarding"
            ;;
        "pihole")
            echo "1. Install Pi-hole: curl -sSL https://install.pi-hole.net | bash"
            echo "2. Configure Pi-hole admin interface"
            echo "3. Set up DNS forwarding rules"
            ;;
    esac
    
    echo ""
    echo "🔧 Useful commands:"
    echo "  Check system status: systemctl status"
    echo "  View firewall status: sudo ufw status verbose"
    echo "  Check network config: ip addr show"
    
    if [[ "$VM_TYPE" == "docker" ]]; then
        echo "  Check Docker: docker --version && docker-compose --version"
    fi
}

# Main execution
main() {
    update_system
    install_common_packages
    configure_ssh
    configure_timezone
    setup_auto_updates
    install_docker
    install_pihole_prereqs
    setup_firewall
    setup_user_directories
    show_completion_summary
    
    echo ""
    echo "⚠️  IMPORTANT: Reboot recommended to apply all changes"
    echo "   Run: sudo reboot"
}

# Run main function
main "$@"