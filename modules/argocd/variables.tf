variable "namespace" {
  description = "Kubernetes namespace to install Argo CD into."
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "argo-cd Helm chart version to install (chart versioning is independent of the app version — see https://artifacthub.io/packages/helm/argo/argo-cd for the mapping)."
  type        = string
  default     = "10.10.1"
}

variable "service_type" {
  description = "argocd-server Service type. NodePort exposes it directly on every node's public IP without a port-forward/tunnel; set back to ClusterIP to only reach it that way."
  type        = string
  default     = "NodePort"
}

variable "node_port_http" {
  description = "NodePort for argocd-server's HTTP port (redirects to HTTPS unless server.insecure is set). Only used when service_type = \"NodePort\"."
  type        = number
  default     = 30080
}

variable "node_port_https" {
  description = "NodePort for argocd-server's HTTPS port. Only used when service_type = \"NodePort\"."
  type        = number
  default     = 30443
}

variable "host" {
  description = "Public IP (or hostname) of the control-plane node, used over SSH to kubectl-apply the app-of-apps root Application."
  type        = string
}

variable "ssh_user" {
  description = "SSH user used to connect to the node."
  type        = string
  default     = "root"
}

variable "ssh_private_key_path" {
  description = "Path to the private key matching the public key installed on the VM."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "git_repo_url" {
  description = "Git repo Argo CD watches for Application manifests (the app-of-apps root). Must be reachable by the cluster without credentials if public, or paired with a repo credentials Secret if private."
  type        = string
  default     = "https://github.com/ykantoni/verda-k8s-infra.git"
}

variable "git_revision" {
  description = "Git revision (branch, tag, or HEAD) the root Application tracks."
  type        = string
  default     = "HEAD"
}

variable "argo_apps_path" {
  description = "Path within git_repo_url containing child Application manifests — Argo CD syncs everything under it automatically."
  type        = string
  default     = "argo-apps"
}
