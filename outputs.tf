output "external_ip" {
  value = google_compute_address.minecraft.address
}

output "crafty_url" {
  value = "https://${google_compute_address.minecraft.address}:8443"
}

output "ssh" {
  value = "gcloud compute ssh ${google_compute_instance.minecraft.name} --zone ${google_compute_instance.minecraft.zone}"
}

output "crafty_password" {
  value = "gcloud compute ssh ${google_compute_instance.minecraft.name} --zone ${google_compute_instance.minecraft.zone} --command 'if sudo test -f /home/mcs/docker/config/crafty-login.txt; then sudo cat /home/mcs/docker/config/crafty-login.txt; else echo \"Crafty password is not ready yet. Recent startup logs:\"; sudo tail -n 80 /var/log/mc-startup.log; fi'"
}
