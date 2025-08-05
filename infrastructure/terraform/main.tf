terraform {
  required_version = ">= 1.0"
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 2.9"
    }
  }
}

# Provider configuration with flexible authentication
provider "proxmox" {
  pm_api_url = "https://${var.proxmox_host}:8006/api2/json"
  
  # Use API token if provided (more secure)
  pm_api_token_id     = var.proxmox_api_token_id != "" ? var.proxmox_api_token_id : null
  pm_api_token_secret = var.proxmox_api_token_secret != "" ? var.proxmox_api_token_secret : null
  
  # Fallback to password authentication
  pm_user     = var.proxmox_api_token_id == "" ? var.proxmox_user : null
  pm_password = var.proxmox_api_token_id == "" ? var.proxmox_password : null
  
  pm_tls_insecure = true
  pm_parallel     = 2
  pm_timeout      = 600
}

# Data source to validate template exists
data "proxmox_vm_qemu" "template" {
  count   = 0  # Disabled by default, enable for validation
  name    = var.template_name
  target_node = var.target_node
}

# Pi-hole VM
resource "proxmox_vm_qemu" "pihole" {
  name         = "pihole-tf"
  vmid         = var.pihole_vmid
  target_node  = var.target_node
  clone        = var.template_name
  full_clone   = true
  
  # VM Resources
  cores    = 1
  memory   = 1024
  sockets  = 1
  cpu      = "host"
  
  # Storage
  disk {
    slot     = 0
    size     = "10G"
    type     = "scsi"
    storage  = var.storage_name
    iothread = 1
  }
  
  # Network
  network {
    model    = "virtio"
    bridge   = "vmbr1"
    firewall = false
  }
  
  # Cloud-init configuration
  os_type    = "cloud-init"
  ipconfig0  = "ip=${var.pihole_ip}/24,gw=${var.homelab_gateway}"
  nameserver = join(" ", var.dns_servers)
  searchdomain = var.search_domain
  
  ciuser     = var.vm_user
  cipassword = var.vm_password
  sshkeys    = file(var.ssh_public_key_path)
  
  # VM Options
  onboot      = true
  agent       = 1
  protection  = false
  startup     = "order=1,up=30"
  
  tags = "terraform,pihole,dns"
  
  # Wait for VM to be ready
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      "echo 'Pi-hole VM is ready'"
    ]
    
    connection {
      type        = "ssh"
      user        = var.vm_user
      private_key = file(var.ssh_private_key_path)
      host        = var.pihole_ip
      timeout     = "5m"
    }
  }
}

# Docker Host VM
resource "proxmox_vm_qemu" "docker_host" {
  name         = "docker-host-tf"
  vmid         = var.docker_vmid
  target_node  = var.target_node
  clone        = var.template_name
  full_clone   = true
  
  # VM Resources (More resources for Docker)
  cores    = 2
  memory   = 2048
  sockets  = 1
  cpu      = "host"
  
  # Storage
  disk {
    slot     = 0
    size     = "20G"
    type     = "scsi"
    storage  = var.storage_name
    iothread = 1
  }
  
  # Network
  network {
    model    = "virtio"
    bridge   = "vmbr1"
    firewall = false
  }
  
  # Cloud-init configuration
  os_type    = "cloud-init"
  ipconfig0  = "ip=${var.docker_host_ip}/24,gw=${var.homelab_gateway}"
  nameserver = join(" ", var.dns_servers)
  searchdomain = var.search_domain
  
  ciuser     = var.vm_user
  cipassword = var.vm_password
  sshkeys    = file(var.ssh_public_key_path)
  
  # VM Options
  onboot      = true
  agent       = 1
  protection  = false
  startup     = "order=2,up=60"
  
  tags = "terraform,docker,services"
  
  # Wait for VM to be ready
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      "echo 'Docker host VM is ready'"
    ]
    
    connection {
      type        = "ssh"
      user        = var.vm_user
      private_key = file(var.ssh_private_key_path)
      host        = var.docker_host_ip
      timeout     = "5m"
    }
  }
  
  depends_on = [proxmox_vm_qemu.pihole]
}