terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  credentials = file(pathexpand("~/.config/gcp/terraform.json"))
  project     = var.project_id
  region      = var.region
  zone        = var.zone
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}