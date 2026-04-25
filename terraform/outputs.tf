output "reserved_ip" {
  description = "The Reserved IPv4 address fronting the droplet."
  value       = module.reserved_ip.ip_address
}

output "droplet_id" {
  description = "Droplet IDs as strings, indexable for future multi-droplet support."
  value       = module.droplet.droplet_ids
}

output "tailscale_hostname" {
  description = "Tailscale MagicDNS hostname of the primary droplet (index 0)."
  value       = module.droplet.tailscale_hostname
}

output "volume_id" {
  description = "Block volume ID holding persistent state under /mnt/data."
  value       = module.block_volume.volume_id
}
