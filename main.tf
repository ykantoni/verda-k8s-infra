# cp1_ip is needed here for argocd_admin_password_command (an SSH command)
# and for the argocd module's SSH-applied app-of-apps root Application —
# Argo CD itself is otherwise reached via the kubeconfig file
# verda-vm-infra generates (see versions.tf).
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

  namespace            = var.argocd_namespace
  chart_version        = var.argocd_chart_version
  host                 = data.terraform_remote_state.vm.outputs.cp1_ip
  ssh_user             = var.ssh_user
  ssh_private_key_path = var.ssh_private_key_path
  git_repo_url         = var.argo_apps_git_repo_url
  git_revision         = var.argo_apps_git_revision
  argo_apps_path       = var.argo_apps_path
  service_type         = var.argocd_service_type
  node_port_http       = var.argocd_node_port_http
  node_port_https      = var.argocd_node_port_https
}
