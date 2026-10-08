variable "ssh_user" {
  description = "SSH user used to connect to the control-plane node (for argocd_admin_password_command, and to kubectl-apply the app-of-apps root Application)."
  type        = string
  default     = "root"
}

variable "ssh_private_key_path" {
  description = "Path to the private key matching the public key verda-vm-infra installed on the VMs (for argocd_admin_password_command, and the app-of-apps root Application)."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "tfstate_location" {
  description = "Path to verda-vm-infra's terraform.tfstate, read for cp1_ip (used by argocd_admin_password_command). Defaults to ../verda-vm-infra/terraform.tfstate (sibling checkout). Override with the TF_VAR_tfstate_location environment variable, not here."
  type        = string
  default     = null
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig verda-vm-infra generates, used to configure the helm provider. Defaults to ../verda-vm-infra/.terraform-kubeconfig.yaml (sibling checkout). Override with the TF_VAR_kubeconfig_path environment variable, not here."
  type        = string
  default     = null
}

variable "argocd_namespace" {
  description = "Kubernetes namespace to install Argo CD into."
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version to install (chart versioning is independent of the app version — see https://artifacthub.io/packages/helm/argo/argo-cd for the mapping). Chart 10.10.1 installs app v3.5.4."
  type        = string
  default     = "10.10.1"
}

variable "argo_apps_git_repo_url" {
  description = "Git repo the app-of-apps root Application watches for child Application manifests. Must be public, or Argo CD needs a matching repo credentials Secret (not set up here)."
  type        = string
  default     = "https://github.com/ykantoni/verda-k8s-infra.git"
}

variable "argo_apps_git_revision" {
  description = "Git revision (branch, tag, or HEAD) the root Application tracks."
  type        = string
  default     = "HEAD"
}

variable "argo_apps_path" {
  description = "Path within argo_apps_git_repo_url containing child Application manifests — Argo CD syncs everything under it automatically, no further terraform apply needed per app."
  type        = string
  default     = "argo-apps"
}
