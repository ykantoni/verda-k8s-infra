# cp1_ip is only needed here for argocd_admin_password_command (an SSH
# command), not for configuring anything — Argo CD itself is reached via
# the kubeconfig file verda-vm-infra generates (see versions.tf).
locals {
  tfstate_location = coalesce(var.tfstate_location, "${path.module}/../verda-vm-infra/terraform.tfstate")
}

data "terraform_remote_state" "vm" {
  backend = "local"

  config = {
    path = local.tfstate_location
  }
}

module "argocd" {
  source = "./modules/argocd"
  providers = {
    helm = helm
  }

  namespace     = var.argocd_namespace
  chart_version = var.argocd_chart_version
}
