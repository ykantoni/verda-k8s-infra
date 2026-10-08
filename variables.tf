variable "ssh_user" {
  description = "SSH user used to connect to both nodes."
  type        = string
  default     = "root"
}

variable "ssh_private_key_path" {
  description = "Path to the private key matching the public key verda-vm-infra installed on the VMs."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "rke2_version" {
  description = "RKE2 version to install, e.g. v1.31.4+rke2r1. Pinned rather than left empty: the install script's \"latest stable\" auto-resolution depends on update.rke2.io/v1-release/channels, which has been returning 404 (an upstream outage, not this repo) — pinning a real tag bypasses it entirely."
  type        = string
  default     = "v1.37.1+rke2r1"
}

variable "tfstate_location" {
  description = "Path to verda-vm-infra's terraform.tfstate, read for cp1_ip/worker1_ip. Defaults to ../verda-vm-infra/terraform.tfstate (sibling checkout). Override with the TF_VAR_tfstate_location environment variable (Terraform's standard env var convention — plain TFSTATE_LOCATION is not read directly)."
  type        = string
  default     = null
}

variable "pod_cidr" {
  description = "Pod IP address range (cluster-cidr)."
  type        = string
  default     = "1.1.0.0/16"
}

variable "service_cidr" {
  description = "Service IP address range (service-cidr)."
  type        = string
  default     = "2.2.0.0/16"
}

variable "cilium_cluster_name" {
  description = "Cilium's cluster identity name (cluster.name Helm value)."
  type        = string
  default     = "verdaclu"
}
