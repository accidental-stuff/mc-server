variable "project_id" {
  description = "GCP project ID"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID: 6-30 lowercase letters, numbers, or hyphens; start with a letter; end with a letter or number."
  }
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid-looking GCP region such as us-central1."
  }
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", var.zone))
    error_message = "zone must be a valid-looking GCP zone such as us-central1-a."
  }
}

variable "r2_access_key" {
  description = "Cloudflare R2 access key"
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = length(trimspace(var.r2_access_key)) > 0
    error_message = "r2_access_key must not be empty."
  }
}

variable "r2_secret_key" {
  description = "Cloudflare R2 secret key"
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = length(trimspace(var.r2_secret_key)) > 0
    error_message = "r2_secret_key must not be empty."
  }
}

variable "r2_endpoint" {
  description = "Cloudflare R2 endpoint URL (https://<account_id>.r2.cloudflarestorage.com)"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^https://[A-Za-z0-9-]+\\.r2\\.cloudflarestorage\\.com/?$", var.r2_endpoint))
    error_message = "r2_endpoint must look like https://<account_id>.r2.cloudflarestorage.com."
  }
}

variable "r2_bucket" {
  description = "R2 bucket name for backups"
  type        = string
  default     = "mc-server-backup"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.r2_bucket))
    error_message = "r2_bucket must be 3-63 characters and contain only lowercase letters, numbers, dots, or hyphens."
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit permissions"
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = length(trimspace(var.cloudflare_api_token)) > 0
    error_message = "cloudflare_api_token must not be empty."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the domain"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Fa-f0-9]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be a 32-character hexadecimal Cloudflare zone ID."
  }
}

variable "domain" {
  description = "Root domain (e.g. example.com)"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$", var.domain))
    error_message = "domain must be a valid DNS name such as example.com."
  }
}

variable "minecraft_subdomain" {
  description = "Subdomain for Minecraft (e.g. play → play.example.com)"
  type        = string
  default     = "play"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$", var.minecraft_subdomain))
    error_message = "minecraft_subdomain must be a single DNS label without leading or trailing hyphens."
  }
}

variable "crafty_subdomain" {
  description = "Subdomain for Crafty panel (e.g. crafty → crafty.example.com)"
  type        = string
  default     = "crafty"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$", var.crafty_subdomain))
    error_message = "crafty_subdomain must be a single DNS label without leading or trailing hyphens."
  }
}

variable "crafty_admin_password" {
  description = "Admin password for the Crafty control panel"
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = length(var.crafty_admin_password) >= 8 && var.crafty_admin_password != "crafty@123"
    error_message = "crafty_admin_password must be at least 8 characters and must not use the old default password."
  }
}
