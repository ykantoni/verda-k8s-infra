output "kubeconfig_command" {
  description = "Fetches the kubeconfig from the control-plane node and rewrites it to use the public IP, so kubectl works from outside Verda Cloud. Written to ~/kubeconfig.yaml, in the local user's home directory, regardless of the current directory."
  value       = "ssh ${var.ssh_user}@${data.terraform_remote_state.vm.outputs.cp1_ip} cat /etc/rancher/rke2/rke2.yaml | sed 's/127.0.0.1/${data.terraform_remote_state.vm.outputs.cp1_ip}/' > ~/kubeconfig.yaml"
}

output "api_server_url" {
  description = "Kubernetes API server address reachable from outside Verda Cloud."
  value       = "https://${data.terraform_remote_state.vm.outputs.cp1_ip}:6443"
}
