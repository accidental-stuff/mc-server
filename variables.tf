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
