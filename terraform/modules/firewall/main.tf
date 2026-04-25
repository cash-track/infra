resource "digitalocean_firewall" "cashtrack" {
  name        = var.name
  droplet_ids = var.droplet_ids

  # HTTP/HTTPS from Cloudflare edges only.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = concat(var.cf_ipv4, var.cf_ipv6)
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = concat(var.cf_ipv4, var.cf_ipv6)
  }

  # Tailscale direct peer-to-peer.
  inbound_rule {
    protocol         = "udp"
    port_range       = "41641"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Diagnostics.
  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound: unrestricted (Tailscale, Docker pulls, Spaces, Cloudflare, GitHub).
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
