variable "role" {
  description = "RKE2 role to bootstrap on this node: \"server\" (control-plane) or \"agent\" (worker)."
  type        = string

  validation {
    condition     = contains(["server", "agent"], var.role)
    error_message = "role must be \"server\" or \"agent\"."
  }
}

variable "token" {
  description = "Shared cluster join token. Generate one value and pass it to every node (server and agents)."
  type        = string
  sensitive   = true
}

variable "rke2_version" {
  description = "RKE2 version to install, e.g. v1.31.4+rke2r1. Empty installs the latest stable release."
  type        = string
  default     = ""
}

variable "server_url" {
  description = "https://<control-plane-ip>:9345 of the RKE2 server. Required when role = \"agent\"; ignored for role = \"server\"."
  type        = string
  default     = null
}

variable "host" {
  description = "Public IP (or hostname) of the already-running VM to bootstrap over SSH."
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
