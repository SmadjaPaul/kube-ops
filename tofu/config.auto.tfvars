cluster_name          = "homeops"
cluster_domain        = "cluster.local"
external_api_endpoint = "api.kube.smadja.dev"

# Smadja environment bindings known from homelab-infra.
# VIPs are deliberately left as TODOs instead of guessing addresses that may
# conflict with existing LAN reservations. See website/docs/getting-started/smadja-porting-todo.md.
network = {
  gateway     = "10.0.20.1"
  vip         = "TODO_LAN_VIP"
  api_lb_vip  = "TODO_API_LB_VIP"
  cidr_prefix = 24
  dns_servers = ["10.0.20.53", "1.1.1.1"]
  bridge      = "vmbr0"
  vlan_id     = 0
}

proxmox_cluster = "tatouine"

versions = {
  talos      = "v1.12.5"
  kubernetes = "1.35.2"
}

talos_image = {
  schematic_path    = "talos/image/schematic.yaml.tftpl"
  update_version    = "v1.13.2" # renovate: github-releases=siderolabs/talos
  proxmox_datastore = "tank-iso"
}

kubernetes_image = {
  update_version = "1.36.1" # renovate: github-releases=kubernetes/kubernetes versioning=loose
}

oidc = {
  issuer_url = "https://auth.smadja.dev/application/o/kubectl/"
  client_id  = "kubectl"
}

# Upstream load-balancer and BLE node addresses/VM IDs belong to the upstream
# environment. Disable them until the local pass allocates collision-free
# values for the Smadja LAN.
enable_lb        = false
lb_nodes         = {}
enable_ble_proxy = false
ble_proxy_nodes  = {}

matter_server_ble_url = ""
