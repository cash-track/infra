provider "digitalocean" {
  # Token sourced from DIGITALOCEAN_TOKEN environment variable
}

provider "tailscale" {
  oauth_client_id     = var.tailscale_oauth_client_id
  oauth_client_secret = var.tailscale_oauth_client_secret
}
