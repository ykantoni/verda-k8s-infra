variable "ssh_user" {
  description = "SSH user used to connect to the control-plane node (only for argocd_admin_password_command)."
  type        = string
  default     = "root"
}

variable "ssh_private_key_path" {
  description = "Path to the private key matching the public key verda-vm-infra installed on the VMs (only for argocd_admin_password_command)."
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
