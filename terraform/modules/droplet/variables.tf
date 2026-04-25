variable "droplet_count" {
  description = "Number of droplets to provision."
  type        = number
}

variable "droplet_hostname" {
  description = "Hostname prefix; the droplet name and Tailscale hostname are formed as `<prefix>-<index>`."
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug."
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

variable "ssh_key_fingerprints" {
  description = "SSH key fingerprints attached to the droplet's root user."
  type        = list(string)
}

variable "ops_ssh_public_key" {
  description = "Public SSH key inserted into the ops user's authorized_keys via cloud-init."
  type        = string
}

variable "tailscale_tags" {
  description = "Tailscale ACL tags applied to the bootstrap auth key."
  type        = list(string)
}

variable "volume_name" {
  description = "DigitalOcean block volume name; used to derive `/dev/disk/by-id/scsi-0DO_Volume_<name>` in cloud-init."
  type        = string
}
