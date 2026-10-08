check "agent_requires_server_url" {
  assert {
    condition     = var.role != "agent" || var.server_url != null
    error_message = "server_url is required when role = \"agent\"."
  }
}

locals {
  script = var.role == "server" ? templatefile("${path.module}/scripts/rke2-server.sh.tftpl", {
    rke2_version = var.rke2_version
    token        = var.token
    pod_cidr     = var.pod_cidr
    service_cidr = var.service_cidr
    cluster_name = var.cilium_cluster_name
    }) : templatefile("${path.module}/scripts/rke2-agent.sh.tftpl", {
    rke2_version = var.rke2_version
    token        = var.token
    server_url   = var.server_url
  })
}

# Bootstraps RKE2 on an already-running VM over SSH. Re-runs whenever the
# target host or the rendered script changes (e.g. a new token or version).
resource "null_resource" "bootstrap" {
  triggers = {
    host       = var.host
    script_sha = sha256(local.script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.script
    destination = "/tmp/rke2-bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/rke2-bootstrap.sh",
      "/tmp/rke2-bootstrap.sh",
    ]
  }
}
