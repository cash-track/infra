provider "digitalocean" {
  # Token sourced from DIGITALOCEAN_TOKEN environment variable
}

provider "tailscale" {
  api_key = var.tailscale_api_key
}
