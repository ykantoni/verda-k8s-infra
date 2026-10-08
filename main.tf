# Reads cp1/worker1's IPs straight from verda-vm-infra's state, so there's
# nothing to copy by hand. Assumes the two repos stay checked out as sibling
# directories (true under the verda-cloud submodule layout), unless
# overridden via TF_VAR_tfstate_location.
locals {
  tfstate_location = coalesce(var.tfstate_location, "${path.module}/../verda-vm-infra/terraform.tfstate")
}

data "terraform_remote_state" "vm" {
  backend = "local"

  config = {
    path = local.tfstate_location
  }
}

# Shared secret the worker uses to join the control-plane's RKE2 cluster.
resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

module "rke2_server" {
  source = "./modules/rke2"

  role                 = "server"
  rke2_version         = var.rke2_version
  token                = random_password.rke2_token.result
  host                 = data.terraform_remote_state.vm.outputs.cp1_ip
  ssh_user             = var.ssh_user
  ssh_private_key_path = var.ssh_private_key_path
}

module "rke2_agent" {
  source = "./modules/rke2"

  role                 = "agent"
  rke2_version         = var.rke2_version
  token                = random_password.rke2_token.result
  server_url           = "https://${data.terraform_remote_state.vm.outputs.cp1_ip}:9345"
  host                 = data.terraform_remote_state.vm.outputs.worker1_ip
  ssh_user             = var.ssh_user
  ssh_private_key_path = var.ssh_private_key_path

  # The agent needs the server already accepting connections on :9345.
  depends_on = [module.rke2_server]
}
