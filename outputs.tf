output "external_ip" {
  value = google_compute_address.minecraft.address
}

output "ssh" {
  value = "gcloud compute ssh ${google_compute_instance.minecraft.name}"
}