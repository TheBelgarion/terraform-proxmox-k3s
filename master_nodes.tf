resource "macaddress" "k3s-masters" {
  count = var.master_nodes_count
}

locals {
  master_node_settings = var.master_node_settings
  master_node_ips      = [for i in range(var.master_nodes_count) : cidrhost(var.control_plane_subnet, i + 1)]
}

resource "random_password" "k3s-server-token" {
  length           = 32
  special          = false
  override_special = "_%@"
}

resource "proxmox_vm_qemu" "k3s-master" {
  depends_on = [
    proxmox_vm_qemu.k3s-support,
  ]

  automatic_reboot = true

  count       = var.master_nodes_count
  target_node = var.proxmox_node
  name        = "${var.cluster_name}-master-${count.index}"

  clone = var.node_template

  pool   = var.proxmox_resource_pool
  scsihw = var.scsihw
  tags   = local.master_node_settings.tags

  vmid = local.master_node_settings.vmid + count.index

  # cores = 2
  cores   = local.master_node_settings.cores
  sockets = local.master_node_settings.sockets
  memory  = local.master_node_settings.memory

  agent  = 1
  onboot = var.onboot

  disk {
    type    = local.master_node_settings.storage_type
    storage = local.master_node_settings.storage_id
    size    = local.master_node_settings.disk_size
  }

  network {
    bridge    = local.master_node_settings.network_bridge
    firewall  = true
    link_down = false
    macaddr   = upper(macaddress.k3s-masters[count.index].address)
    model     = "virtio"
    queues    = 0
    rate      = 0
    tag       = local.master_node_settings.network_tag
  }

  lifecycle {
    ignore_changes = [
      ciuser,
      ssh_private_key,
      disk,
      tags,
      network
    ]
  }

  os_type = "cloud-init"

  ciuser  = local.master_node_settings.user
  sshkeys = file(var.ssh_key_files.publ)

  ipconfig0 = "ip=${local.master_node_ips[count.index]}/${local.lan_subnet_cidr_bitnum},gw=${var.network_gateway}"

  nameserver = var.nameserver

  connection {
    type        = "ssh"
    user        = local.master_node_settings.user
    host        = local.master_node_ips[count.index]
    private_key = file(var.ssh_key_files.priv)
  }

  provisioner "remote-exec" {
    inline = [
      templatefile("${path.module}/scripts/install-k3s-server.sh.tftpl", {
        mode         = "server"
        tokens       = [random_password.k3s-server-token.result]
        alt_names    = concat([local.support_node_ip], var.api_hostnames)
        server_hosts = []
        node_taints  = ["CriticalAddonsOnly=true:NoExecute"]
        disable      = var.k3s_disable_components
        datastores = [
          {
            host     = "${local.support_node_ip}:3306"
            name     = "k3s"
            user     = "k3s"
            password = random_password.k3s-master-db-password.result
          }
        ]
        http_proxy = var.http_proxy
      })
    ]
  }
}

resource "terraform_data" "kubeconfig" {
  provisioner "remote-exec" {
    inline = [
      "sudo cp --no-preserve=ownership /etc/rancher/k3s/k3s.yaml ~/${var.kube_config_file}",
      "sudo chown ${local.master_node_settings.user} ${var.kube_config_file}",
      "sed -i -r 's/127.0.0.1:6443/${local.support_node_ip}:6443/gi' ~/${var.kube_config_file}"
    ]
    connection {
      type        = "ssh"
      user        = local.master_node_settings.user
      private_key = file(var.ssh_key_files.priv)
      host        = local.master_node_ips[0]
      timeout     = "10s"
    }
  }
  provisioner "local-exec" {
    command = "scp -i ${var.ssh_key_files.priv} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${local.master_node_settings.user}@${local.master_node_ips[0]}:~/${var.kube_config_file} ${var.kube_config_file}"
  }
  depends_on = [
    proxmox_vm_qemu.k3s-support,
    proxmox_vm_qemu.k3s-master,
    proxmox_vm_qemu.k3s-worker,
  ]
}
