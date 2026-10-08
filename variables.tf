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
  description = "RKE2 version to install, e.g. v1.31.4+rke2r1. Empty installs the latest stable release."
  type        = string
  default     = ""
}
