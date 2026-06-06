variable "project_id" {}

variable "region" {
  default = "us-central1"
}

variable "zone" {
  default = "us-central1-a"
}
variable "r2_access_key" {
  sensitive = true
}

variable "r2_secret_key" {
  sensitive = true
}

# Your Cloudflare R2 endpoint URL
# Format: https://<account_id>.r2.cloudflarestorage.com
variable "r2_endpoint" {}

# The R2 bucket name to use for backups
variable "r2_bucket" {
  default = "mc-server-backup"
}


variable "cloudflare_api_token" {
  sensitive = true
}

variable "cloudflare_zone_id" {}

variable "domain" {
  description = "Your root domain, e.g. example.com"
}

variable "minecraft_subdomain" {
  default     = "play"
  description = "Subdomain for Minecraft, e.g. play → play.example.com"
}

variable "crafty_subdomain" {
  default     = "crafty"
  description = "Subdomain for Crafty panel, e.g. crafty → crafty.example.com"
}