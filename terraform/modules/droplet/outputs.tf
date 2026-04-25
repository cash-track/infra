output "droplet_ids" {
  description = "Droplet IDs as strings, indexable for future multi-droplet support."
  value       = [for d in digitalocean_droplet.host : d.id]
}

output "tailscale_hostname" {
  description = "Tailscale MagicDNS hostname of the primary droplet."
  value       = digitalocean_droplet.host[0].name
}
