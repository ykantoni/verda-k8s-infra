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
