# VM Information
output "pihole_vm_info" {
  description = "Pi-hole VM information"
  value = {
    name        = proxmox_vm_qemu.pihole.name
    vmid        = proxmox_vm_qemu.pihole.vmid
    ip_address  = var.pihole_ip
    status      = "created"
    ssh_command = "ssh ${var.vm_user}@${var.pihole_ip}"
  }
}

output "docker_host_vm_info" {
  description = "Docker host VM information"
  value = {
    name        = proxmox_vm_qemu.docker_host.name
    vmid        = proxmox_vm_qemu.docker_host.vmid
    ip_address  = var.docker_host_ip
    status      = "created"
    ssh_command = "ssh ${var.vm_user}@${var.docker_host_ip}"
  }
}

# Network Information
output "network_info" {
  description = "Homelab network configuration"
  value = {
    network        = "10.0.10.0/24"
    gateway        = var.homelab_gateway
    dns_servers    = var.dns_servers
    search_domain  = var.search_domain
  }
}

# Service URLs (Internal)
output "internal_service_urls" {
  description = "Internal service URLs for homelab network"
  value = {
    pihole_admin     = "http://${var.pihole_ip}/admin"
    portainer        = "http://${var.docker_host_ip}:9000"
    uptime_kuma      = "http://${var.docker_host_ip}:3001"
  }
}

# SSH Connection Commands
output "ssh_connections" {
  description = "SSH connection commands for VMs"
  value = {
    pihole      = "ssh ${var.vm_user}@${var.pihole_ip}"
    docker_host = "ssh ${var.vm_user}@${var.docker_host_ip}"
  }
}

# Ansible Inventory Data
output "ansible_inventory" {
  description = "Data for generating Ansible inventory"
  value = {
    pihole_hosts = [{
      name         = proxmox_vm_qemu.pihole.name
      ansible_host = var.pihole_ip
    }]
    docker_hosts = [{
      name         = proxmox_vm_qemu.docker_host.name
      ansible_host = var.docker_host_ip
    }]
    all_vars = {
      ansible_user                 = var.vm_user
      ansible_ssh_private_key_file = var.ssh_private_key_path
      ansible_python_interpreter   = "/usr/bin/python3"
      homelab_gateway             = var.homelab_gateway
      dns_servers                 = var.dns_servers
    }
  }
}

# Next Steps Information
output "next_steps" {
  description = "Next steps after Terraform deployment"
  value = [
    "1. Test SSH connectivity to VMs",
    "2. Update Ansible inventory with VM IPs",
    "3. Run Ansible playbooks to configure services",
    "4. Verify services are accessible",
    "5. Configure external port forwarding on Proxmox host"
  ]
}

# Terraform State Information
output "terraform_info" {
  description = "Terraform deployment information"
  value = {
    workspace   = terraform.workspace
    created_at  = timestamp()
    vm_count    = 2
    environment = var.environment
  }
}