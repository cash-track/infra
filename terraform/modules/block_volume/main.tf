resource "digitalocean_volume" "data" {
  name        = var.volume_name
  region      = var.region
  size        = var.volume_size_gb
  description = "cash-track persistent state (mysql, prometheus, loki, tempo, grafana, alertmanager)"
  tags        = [var.volume_tag]

  lifecycle {
    prevent_destroy = true
  }
}

resource "digitalocean_volume_attachment" "data" {
  droplet_id = var.droplet_id
  volume_id  = digitalocean_volume.data.id
}
