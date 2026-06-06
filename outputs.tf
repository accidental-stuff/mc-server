output "external_ip" {
  description = "Raw public IP of the VM"
  value       = google_compute_address.minecraft.address
}

output "minecraft_domain" {
  description = "Add this in your Minecraft server list"
  value       = "${var.minecraft_subdomain}.${var.domain}"
}

output "crafty_url" {
  description = "Crafty web panel URL (valid cert via Caddy)"
  value       = "https://${var.crafty_subdomain}.${var.domain}"
}

output "crafty_password" {
  description = "Run this to get Crafty credentials (or tail logs if not ready)"
  value       = "gcloud compute ssh ${google_compute_instance.minecraft.name} --zone ${google_compute_instance.minecraft.zone} --command 'if sudo test -f /home/mcs/docker/config/crafty-login.txt; then sudo cat /home/mcs/docker/config/crafty-login.txt; else echo \"Crafty password is not ready yet. Recent startup logs:\"; sudo tail -n 80 /var/log/mc-startup.log; fi'"
}

output "ssh" {
  description = "SSH into the VM"
  value       = "gcloud compute ssh ${google_compute_instance.minecraft.name} --zone ${google_compute_instance.minecraft.zone}"
}

output "startup_logs" {
  description = "Tail startup logs live"
  value       = "gcloud compute ssh ${google_compute_instance.minecraft.name} --zone ${google_compute_instance.minecraft.zone} --command 'sudo tail -f /var/log/mc-startup.log'"
}

output "caddy_logs" {
  description = "Tail Caddy logs (useful if cert isn't provisioning)"
  value       = "gcloud compute ssh ${google_compute_instance.minecraft.name} --zone ${google_compute_instance.minecraft.zone} --command 'docker logs caddy -f'"
}