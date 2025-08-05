# Infrastructure as Code Usage Guide

This guide explains how to use Terraform and Ansible to replicate the homelab infrastructure automatically.

## 📋 Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Detailed Setup](#detailed-setup)
- [Terraform Workflow](#terraform-workflow)
- [Ansible Workflow](#ansible-workflow)
- [Testing and Validation](#testing-and-validation)
- [Troubleshooting](#troubleshooting)
- [Advanced Usage](#advanced-usage)

## 🛠️ Prerequisites

### System Requirements
- **Control Machine**: Linux, macOS, or Windows WSL2
- **Proxmox VE**: Version 7.0+ with API access
- **Network**: Homelab network (vmbr1) already configured
- **Template**: Ubuntu 22.04 cloud-init template prepared

### Required Tools
```bash
# Terraform (latest version)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Ansible
sudo apt update && sudo apt install ansible

# Additional tools
sudo apt install jq curl dig
```

### SSH Key Setup
```bash
# Generate SSH key if you don't have one
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""

# Display public key (copy this to VM template)
cat ~/.ssh/id_rsa.pub
```

## 🚀 Quick Start

### 1. Clone Repository Structure
```bash
mkdir -p ~/homelab-infrastructure/infrastructure/{terraform,ansible}
cd ~/homelab-infrastructure
```

### 2. Setup Terraform
```bash
cd infrastructure/terraform

# Copy and customize variables
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars  # Edit with your values

# Validate and deploy
./scripts/validate.sh
./scripts/deploy.sh
```

### 3. Setup Ansible
```bash
cd ../ansible

# Update inventory from Terraform
./scripts/update-inventory.sh

# Deploy services
./scripts/deploy.sh
```

### 4. Verify Deployment
```bash
# Test services
./scripts/test-services.sh

# View service URLs
terraform output
```

## 📚 Detailed Setup

### Proxmox Preparation

#### 1. Create API User (Recommended)
```bash
# On Proxmox host
pveum user add terraform@pve --password terraform123
pveum aclmod / -user terraform@pve -role Administrator

# Create API token (more secure)
pveum user token add terraform@pve terraform-token --privsep=0
```

#### 2. Create VM Template
```bash
# Download Ubuntu cloud image
cd /var/lib/vz/template/iso/
wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img

# Create template VM
qm create 900 --name ubuntu-22.04-template --memory 1024 --cores 1 --net0 virtio,bridge=vmbr1
qm importdisk 900 ubuntu-22.04-server-cloudimg-amd64.img local-lvm
qm set 900 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-900-disk-0
qm set 900 --boot c --bootdisk scsi0
qm set 900 --ide2 local-lvm:cloudinit
qm set 900 --serial0 socket --vga serial0
qm set 900 --agent enabled=1

# Configure default user
qm set 900 --ciuser homelab
qm set 900 --cipassword homelab123
qm set 900 --sshkeys ~/.ssh/id_rsa.pub

# Convert to template
qm template 900
```

## 🏗️ Terraform Workflow

### Configuration Files

#### terraform.tfvars
```hcl
# Required settings
proxmox_host = "192.168.1.100"  # Your Proxmox IP
target_node  = "pve"            # Your node name

# Authentication (choose one method)
# Method 1: API Token (recommended)
proxmox_api_token_id     = "terraform@pve!terraform-token"
proxmox_api_token_secret = "your-token-secret"

# Method 2: Username/Password
# proxmox_user     = "terraform@pve"
# proxmox_password = "terraform123"

# VM Configuration
vm_password = "homelab123"

# Optional customizations
pihole_ip      = "10.0.10.11"
docker_host_ip = "10.0.10.21"
pihole_vmid    = 901
docker_vmid    = 902
```

### Deployment Commands

#### Standard Deployment
```bash
cd infrastructure/terraform

# Validate configuration
./scripts/validate.sh

# Plan deployment
terraform plan

# Deploy infrastructure
./scripts/deploy.sh
```

#### Advanced Deployment
```bash
# Deploy specific resources
terraform apply -target=proxmox_vm_qemu.pihole

# Use different variable file
terraform apply -var-file="production.tfvars"

# Enable detailed logging
TF_LOG=DEBUG terraform apply
```

### Terraform Outputs
```bash
# View all outputs
terraform output

# Specific output
terraform output pihole_vm_info
terraform output ssh_connections

# JSON format
terraform output -json | jq .
```

## 🔧 Ansible Workflow

### Inventory Management

#### Update from Terraform
```bash
cd infrastructure/ansible

# Auto-update inventory
./scripts/update-inventory.sh

# Manual inventory edit
nano inventory/hosts.yml
```

#### Manual Inventory
```yaml
all:
  vars:
    ansible_user: homelab
    ansible_ssh_private_key_file: ~/.ssh/id_rsa
    ansible_python_interpreter: /usr/bin/python3
  children:
    pihole:
      hosts:
        pihole-tf:
          ansible_host: 10.0.10.11
    docker_hosts:
      hosts:
        docker-host-tf:
          ansible_host: 10.0.10.21
```

### Deployment Options

#### Full Deployment
```bash
./scripts/deploy.sh
```

#### Selective Deployment
```bash
# Deploy only Pi-hole
./scripts/deploy.sh -p pihole-only.yml

# Deploy only Docker services
./scripts/deploy.sh -p docker-only.yml

# Deploy to specific hosts
./scripts/deploy.sh -l pihole

# Deploy specific tasks
./scripts/deploy.sh -t docker,monitoring
```

#### Dry Run Testing
```bash
# Check mode (no changes)
./scripts/deploy.sh -c

# Verbose output
./scripts/deploy.sh -v
```

### Manual Playbook Execution
```bash
# Basic execution
ansible-playbook playbooks/site.yml

# With custom inventory
ansible-playbook -i custom-inventory.yml playbooks/site.yml

# Limit to specific hosts
ansible-playbook playbooks/site.yml --limit docker_hosts

# Run specific tags
ansible-playbook playbooks/site.yml --tags security,docker
```

## 🧪 Testing and Validation

### Terraform Testing
```bash
cd infrastructure/terraform

# Validate configuration
./scripts/validate.sh

# Test VM connectivity
./scripts/test-connectivity.sh

# Format code
terraform fmt

# Security scan (if tfsec installed)
tfsec .
```

### Ansible Testing
```bash
cd infrastructure/ansible

# Validate configuration
./scripts/validate.sh

# Test connectivity
ansible all -m ping

# Test services
./scripts/test-services.sh

# Dry run playbook
ansible-playbook playbooks/site.yml --check --diff
```

### Service Validation
```bash
# Pi-hole tests
curl -I http://10.0.10.11/admin
dig @10.0.10.11 google.com
dig @10.0.10.11 doubleclick.net  # Should be blocked

# Docker service tests
curl -I http://10.0.10.21:9000  # Portainer
curl -I http://10.0.10.21:3001  # Uptime Kuma

# SSH tests
ssh homelab@10.0.10.11 "docker --version" 2>/dev/null || echo "Not a Docker host"
ssh homelab@10.0.10.21 "docker ps"
```

## 🔧 Troubleshooting

### Common Terraform Issues

#### Authentication Problems
```bash
# Test API connectivity
curl -k -u "terraform@pve:password" \
  "https://PROXMOX_IP:8006/api2/json/version"

# Test with API token
curl -k -H "Authorization: PVEAPIToken=terraform@pve!terraform-token=TOKEN_SECRET" \
  "https://PROXMOX_IP:8006/api2/json/version"
```

#### Template Issues
```bash
# List available templates
qm list | grep template

# Check template configuration
qm config 900
```

#### Network Issues
```bash
# Check bridge configuration
ip addr show vmbr1

# Test gateway connectivity
ping 10.0.10.1

# Check NAT rules
iptables -t nat -L POSTROUTING
```

### Common Ansible Issues

#### SSH Connectivity
```bash
# Test direct SSH
ssh -o StrictHostKeyChecking=no homelab@10.0.10.11

# Check SSH key
ssh-add -l
ssh-add ~/.ssh/id_rsa

# Debug SSH connection
ssh -vvv homelab@10.0.10.11
```

#### Privilege Escalation
```bash
# Test sudo access
ansible all -m shell -a "sudo whoami"

# Check sudo configuration
ansible all -m shell -a "sudo -l"
```

#### Service Issues
```bash
# Check service status
ansible docker_hosts -m shell -a "systemctl status docker"
ansible pihole -m shell -a "systemctl status pihole-FTL"

# Check logs
ansible all -m shell -a "journalctl -u docker --no-pager -n 20"
```

### Network Debugging
```bash
# Check VM network configuration
ansible all -m shell -a "ip addr show"
ansible all -m shell -a "ip route show"

# Test DNS resolution
ansible all -m shell -a "nslookup google.com"

# Test internet connectivity
ansible all -m shell -a "ping -c 1 8.8.8.8"
```

## 🚀 Advanced Usage

### Custom Variables
```hcl
# terraform/custom.tfvars
environment = "production"
vm_password = "super-secure-password"

# Larger VMs for production
docker_host_memory = 4096
docker_host_cores = 4
```

### Multiple Environments
```bash
# Use workspace for environments
terraform workspace new production
terraform workspace new staging

# Deploy to specific workspace
terraform workspace select production
terraform apply -var-file="production.tfvars"
```

### Ansible Vault for Secrets
```bash
# Create vault file
ansible-vault create group_vars/all/vault.yml

# Add encrypted variables
vault_pihole_password: supersecretpassword
vault_vm_password: anothersecret

# Run with vault
ansible-playbook playbooks/site.yml --ask-vault-pass
```

### Custom Roles
```bash
# Create custom role
ansible-galaxy init roles/nginx-proxy

# Use in playbook
- hosts: docker_hosts
  roles:
    - docker
    - nginx-proxy
```

### CI/CD Integration
```yaml
# .github/workflows/deploy.yml
name: Deploy Infrastructure

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
      - name: Terraform Apply
        run: |
          cd infrastructure/terraform
          terraform init
          terraform apply -auto-approve
```

## 📊 Monitoring and Maintenance

### Regular Maintenance
```bash
# Update VM packages
ansible all -m apt -a "upgrade=safe" --become

# Restart services if needed
ansible all -m reboot --become

# Check disk usage
ansible all -m shell -a "df -h"
```

### Backup Procedures
```bash
# Backup Terraform state
cp terraform.tfstate terraform.tfstate.backup.$(date +%Y%m%d)

# Backup VM configurations
ansible all -m archive -a "path=/home/homelab/homelab dest=/tmp/homelab-backup.tar.gz"
```

### Scaling Operations
```bash
# Add new VM to terraform
# Edit main.tf to add new resource

# Scale existing VMs
terraform apply -var="docker_host_memory=4096"

# Add new hosts to Ansible
# Edit inventory/hosts.yml
```

This completes the comprehensive usage guide for your Infrastructure as Code setup. The combination of Terraform and Ansible provides a powerful, reproducible way to deploy and manage your homelab infrastructure.