region           = "ams3"
droplet_count    = 1
droplet_hostname = "cashtrack-prod"
droplet_size     = "s-4vcpu-8gb"
droplet_image    = "ubuntu-24-04-x64"

volume_size_gb = 25
volume_name    = "cashtrack-data"
volume_tag     = "cashtrack-data"

domain = "cash-track.app"

# Operator: replace with the public MD5 fingerprint(s) of the ops SSH key
# (run `doctl compute ssh-key list` to obtain).
ssh_key_fingerprints = ["2f:b7:25:a6:04:b1:fe:9e:b3:99:a5:af:00:4b:7f:8d"]

# Operator: replace with the matching public key in OpenSSH single-line format
# (e.g. the contents of ~/.ssh/cashtrack_ops.pub).
ops_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIcRk11JzJTAza6IN1/L62XY6mpKKrdqu/ZdgRWlWre5 vovikems@gmail.com"

tailscale_tags = ["tag:cashtrack-prod"]

cf_ipv4_url = "https://www.cloudflare.com/ips-v4"
cf_ipv6_url = "https://www.cloudflare.com/ips-v6"

enable_cloudflare_dns = false
