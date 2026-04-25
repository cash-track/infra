data "http" "cf_ipv4" {
  url = var.cf_ipv4_url
}

data "http" "cf_ipv6" {
  url = var.cf_ipv6_url
}

locals {
  cf_ipv4 = compact(split("\n", trimspace(data.http.cf_ipv4.response_body)))
  cf_ipv6 = compact(split("\n", trimspace(data.http.cf_ipv6.response_body)))
}

module "droplet" {
  source = "./modules/droplet"

  droplet_count        = var.droplet_count
  droplet_hostname     = var.droplet_hostname
  region               = var.region
  droplet_size         = var.droplet_size
  droplet_image        = var.droplet_image
  ssh_key_fingerprints = var.ssh_key_fingerprints
  ops_ssh_public_key   = var.ops_ssh_public_key
  tailscale_tags       = var.tailscale_tags
  volume_name          = var.volume_name
}

module "block_volume" {
  source = "./modules/block_volume"

  region         = var.region
  volume_name    = var.volume_name
  volume_size_gb = var.volume_size_gb
  volume_tag     = var.volume_tag
  droplet_id     = tonumber(module.droplet.droplet_ids[0])
}

module "reserved_ip" {
  source = "./modules/reserved_ip"

  region     = var.region
  droplet_id = tonumber(module.droplet.droplet_ids[0])
}

module "firewall" {
  source = "./modules/firewall"

  name        = var.droplet_hostname
  droplet_ids = [for id in module.droplet.droplet_ids : tonumber(id)]
  cf_ipv4     = local.cf_ipv4
  cf_ipv6     = local.cf_ipv6
}
