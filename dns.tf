# A record MC
resource "cloudflare_record" "minecraft" {
  zone_id = var.cloudflare_zone_id
  name    = var.minecraft_subdomain
  content = google_compute_address.minecraft.address
  type    = "A"
  proxied = false 
  ttl     = 300
  allow_overwrite = true
}

# SRV record — lets players connect with just "yourdomain.com" (no :25565)
resource "cloudflare_record" "minecraft_srv" {
  zone_id = var.cloudflare_zone_id
  name    = "_minecraft._tcp"
  type    = "SRV"
  ttl     = 300
  allow_overwrite = true
  data {
    service  = "_minecraft"
    proto    = "_tcp"
    name     = var.domain
    priority = 0
    weight   = 5
    port     = 25565
    target   = "${var.minecraft_subdomain}.${var.domain}"
  }
}

# A record for Crafty panel (crafty.yourdomain.com → GCP IP)
resource "cloudflare_record" "crafty" {
  zone_id = var.cloudflare_zone_id
  name    = var.crafty_subdomain
  content = google_compute_address.minecraft.address
  type    = "A"
  proxied = false 
  ttl     = 300
  allow_overwrite = true
}