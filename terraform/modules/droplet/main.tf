resource "tailscale_tailnet_key" "bootstrap" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 3600
  description   = "cashtrack droplet bootstrap"
  tags          = var.tailscale_tags
}

resource "digitalocean_droplet" "host" {
  count = var.droplet_count

  name     = "${var.droplet_hostname}-${count.index}"
  region   = var.region
  size     = var.droplet_size
  image    = var.droplet_image
  ssh_keys = var.ssh_key_fingerprints
  tags     = ["cashtrack-prod"]

  user_data = templatefile("${path.module}/templates/cloud-init.yaml", {
    hostname           = "${var.droplet_hostname}-${count.index}"
    ops_ssh_public_key = var.ops_ssh_public_key
    tailscale_authkey  = tailscale_tailnet_key.bootstrap.key
    volume_name        = var.volume_name
  })

  lifecycle {
    # cloud-init runs once on first boot; key rotation must not reprovision
    # a running server.
    ignore_changes = [user_data]
  }
}
