variable "region" {
  description = "DigitalOcean region slug (must match the droplet region)."
  type        = string
}

variable "volume_name" {
  description = "Block volume name. Cloud-init derives `/dev/disk/by-id/scsi-0DO_Volume_<name>` from this."
  type        = string
}

variable "volume_size_gb" {
  description = "Volume size in gigabytes."
  type        = number
}

variable "volume_tag" {
  description = "DigitalOcean tag applied to the volume."
  type        = string
}

variable "droplet_id" {
  description = "Droplet ID to attach the volume to."
  type        = number
}
