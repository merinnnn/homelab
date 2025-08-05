# Proxmox Connection Variables
variable "proxmox_host" {
  description = "Proxmox host IP address"
  type        = string
  
  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.proxmox_host))
    error_message = "Proxmox host must be a valid IP address."
  }
}

variable "proxmox_user" {
  description = "Proxmox username (e.g., root@pam or terraform@pve)"
  type        = string
  default     = "terraform@pve"
}

variable "proxmox_password" {
  description = "Proxmox password (used if API token not provided)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_api_token_id" {
  description = "Proxmox API Token ID (format: user@realm!tokenname)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API Token Secret"
  type        = string
  sensitive   = true
  default     = ""
}

# Infrastructure Variables
variable "target_node" {
  description = "Proxmox node name"
  type        = string
  
  validation {
    condition     = length(var.target_node) > 0
    error_message = "Target node name cannot be empty."
  }
}

variable "storage_name" {
  description = "Proxmox storage name"
  type        = string
  default     = "local-lvm"
}

variable "template_name" {
  description = "VM template name for cloning"
  type        = string
  default     = "ubuntu-22.04-template"
}

# Network Configuration
variable "homelab_gateway" {
  description = "Homelab network gateway IP"
  type        = string
  default     = "10.0.10.1"
  
  validation {
    condition     = can(regex("^10\\.0\\.10\\.[0-9]{1,3}$", var.homelab_gateway))
    error_message = "Gateway must be in the 10.0.10.0/24 network."
  }
}

variable "pihole_ip" {
  description = "Pi-hole VM IP address"
  type        = string
  default     = "10.0.10.11"
  
  validation {
    condition     = can(regex("^10\\.0\\.10\\.[0-9]{1,3}$", var.pihole_ip))
    error_message = "Pi-hole IP must be in the 10.0.10.0/24 network."
  }
}

variable "docker_host_ip" {
  description = "Docker host VM IP address"
  type        = string
  default     = "10.0.10.21"
  
  validation {
    condition     = can(regex("^10\\.0\\.10\\.[0-9]{1,3}$", var.docker_host_ip))
    error_message = "Docker host IP must be in the 10.0.10.0/24 network."
  }
}

variable "dns_servers" {
  description = "DNS servers for VMs"
  type        = list(string)
  default     = ["8.8.8.8", "1.1.1.1"]
  
  validation {
    condition     = length(var.dns_servers) > 0
    error_message = "At least one DNS server must be specified."
  }
}

variable "search_domain" {
  description = "Search domain for VMs"
  type        = string
  default     = "homelab.local"
}

# VM Configuration
variable "vm_user" {
  description = "Default user for VMs"
  type        = string
  default     = "homelab"
  
  validation {
    condition     = length(var.vm_user) > 0
    error_message = "VM user cannot be empty."
  }
}

variable "vm_password" {
  description = "Default password for VM user"
  type        = string
  sensitive   = true
  
  validation {
    condition     = length(var.vm_password) >= 8
    error_message = "VM password must be at least 8 characters long."
  }
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key file"
  type        = string
  default     = "~/.ssh/id_rsa"
}

# VM IDs
variable "pihole_vmid" {
  description = "VM ID for Pi-hole VM"
  type        = number
  default     = 901
  
  validation {
    condition     = var.pihole_vmid >= 100 && var.pihole_vmid <= 999999999
    error_message = "VM ID must be between 100 and 999999999."
  }
}

variable "docker_vmid" {
  description = "VM ID for Docker host VM"
  type        = number
  default     = 902
  
  validation {
    condition     = var.docker_vmid >= 100 && var.docker_vmid <= 999999999
    error_message = "VM ID must be between 100 and 999999999."
  }
}

# Environment Configuration
variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "homelab"
  
  validation {
    condition     = contains(["dev", "staging", "prod", "homelab"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod, homelab."
  }
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "homelab-infrastructure"
}