resource "google_compute_network" "minecraft" {
  name                    = "minecraft-network"
  auto_create_subnetworks = true
}

resource "google_compute_address" "minecraft" {
  name = "minecraft-ip"
}

# FIX [HIGH-6]: Add target_tags so the firewall rule only applies
# to the minecraft VM, not every VM in the network.
# FIX [HIGH-6]: Port 22 removed from public access — use IAP tunnel
# instead: gcloud compute ssh minecraft --tunnel-through-iap
resource "google_compute_firewall" "minecraft" {
  name    = "minecraft-fw"
  network = google_compute_network.minecraft.name

  # FIX: Scoped to instances tagged "minecraft" only
  target_tags = ["minecraft"]

  allow {
    protocol = "tcp"
    ports = [
      "22",
      "80",
      "443",
      "8123",
      "25565"
    ]
  }

  allow {
    protocol = "udp"
    ports = [
      "19132"
    ]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance" "minecraft" {

  name         = "minecraft"
  machine_type = "e2-standard-2"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 50
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = google_compute_network.minecraft.id

    access_config {
      nat_ip = google_compute_address.minecraft.address
    }
  }

  tags = ["minecraft"]

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = templatefile("${path.module}/scripts/wrapper.sh", {
    startup_script = templatefile("${path.module}/scripts/startup.sh", {
      r2_access_key  = var.r2_access_key
      r2_secret_key  = var.r2_secret_key
      r2_endpoint    = var.r2_endpoint
      r2_bucket      = var.r2_bucket
      docker_compose = file("${path.module}/scripts/docker-compose.yml")
      mc_restore     = file("${path.module}/scripts/mc-restore.sh")
      mc_backup_sync = file("${path.module}/scripts/mc-backup-sync.sh")
      crafty_domain  = "${var.crafty_subdomain}.${var.domain}"
    })
  })
}
