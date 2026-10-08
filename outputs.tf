output "argocd_admin_password_command" {
  description = "Fetches Argo CD's initial admin password (username: admin)."
  value       = "ssh -o StrictHostKeyChecking=accept-new ${var.ssh_user}@${data.terraform_remote_state.vm.outputs.cp1_ip} kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
