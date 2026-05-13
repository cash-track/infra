variable "region" {
  description = "DigitalOcean region slug for all resources."
  type        = string
}

variable "droplet_count" {
  description = "Number of droplets in the cashtrack pool. Index 0 holds the Reserved IP; multi-droplet is future work."
  type        = number
}

variable "droplet_hostname" {
  description = "Hostname prefix for the droplet; used as Tailscale MagicDNS name and DO droplet name."
  type        = string
}

variable "droplet_size" {
  description = "DigitalOcean droplet size slug."
  type        = string
}

variable "droplet_image" {
  description = "DigitalOcean droplet image slug."
  type        = string
}

variable "volume_size_gb" {
  description = "Block volume size in gigabytes."
  type        = number
}

variable "volume_name" {
  description = "DigitalOcean block volume name. Also used as the ext4 filesystem label by cloud-init."
  type        = string
}

variable "volume_tag" {
  description = "DigitalOcean tag applied to the block volume."
  type        = string
}

variable "domain" {
  description = "Apex domain served by the droplet."
  type        = string
}

variable "ssh_key_fingerprints" {
  description = "DigitalOcean SSH key fingerprints attached to the droplet (root authorized_keys). Public MD5 fingerprints, not the keys themselves."
  type        = list(string)
}

variable "ops_ssh_public_key" {
  description = "Public SSH key (single-line OpenSSH format) injected into the ops user's authorized_keys via cloud-init."
  type        = string
}

variable "tailscale_tags" {
  description = "Tailscale ACL tags applied to the bootstrap auth key and to the droplet on `tailscale up`."
  type        = list(string)
}

variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID used to authenticate the tailscale provider."
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth client secret used to authenticate the tailscale provider."
  type        = string
  sensitive   = true
}

variable "cf_ipv4_url" {
  description = "Cloudflare IPv4 ranges feed; one CIDR per line."
  type        = string
}

variable "cf_ipv6_url" {
  description = "Cloudflare IPv6 ranges feed; one CIDR per line."
  type        = string
}

variable "enable_cloudflare_dns" {
  description = "Whether Terraform manages Cloudflare DNS A records pointing at the Reserved IP."
  type        = bool
}
