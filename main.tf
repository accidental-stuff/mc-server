resource "google_compute_network" "minecraft" {
  name                    = "minecraft-network"
  auto_create_subnetworks = true
}

resource "google_compute_address" "minecraft" {
  name = "minecraft-ip"
}

resource "google_compute_firewall" "minecraft" {
  name    = "minecraft-fw"
  network = google_compute_network.minecraft.name

  allow {
    protocol = "tcp"
    ports = [
      "22",
      "8443",
      "25565"
    ]
  }

  source_ranges = [
    "0.0.0.0/0"
  ]
}

resource "google_compute_instance" "minecraft" {

  name         = "minecraft"
  machine_type = "n2-standard-2"
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

  tags = [
    "minecraft"
  ]

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = file("${path.module}/scripts/startup.sh")
}