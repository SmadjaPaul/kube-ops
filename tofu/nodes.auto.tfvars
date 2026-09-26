nodes_config = {
  "homeops-01" = {
    machine_type  = "controlplane"
    host_node     = "tatouine"
    ip            = "10.0.20.60"
    vm_id         = 101
    datastore_id  = "nvme-vm"
    root_disk_size = 100
    ram_dedicated = 32768
    cpu_units     = 1024
    description   = "Smadja homeops single-node Talos control plane"
    tags          = ["k8s", "control-plane", "homeops"]
    on_boot       = true
    upgrade       = false
  }
}
