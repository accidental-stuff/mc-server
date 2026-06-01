terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  credentials = file("~/.config/gcp/terraform.json")

  project = var.project_id
  region  = var.region
  zone    = var.zone
}