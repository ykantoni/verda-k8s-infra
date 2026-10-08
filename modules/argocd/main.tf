resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
}

locals {
  root_app_manifest = templatefile("${path.module}/manifests/root-app.yaml.tftpl", {
    namespace      = var.namespace
    git_repo_url   = var.git_repo_url
    git_revision   = var.git_revision
    argo_apps_path = var.argo_apps_path
  })
}

# Bootstraps the "app of apps": one root Argo CD Application, applied
# directly over SSH (not via GitOps, since something has to create the
# first one), that points at argo_apps_path in git_repo_url. Argo CD then
# syncs everything under that path itself — adding a new Application
# manifest there needs no further `terraform apply`.
resource "null_resource" "root_app" {
  depends_on = [helm_release.argocd]

  triggers = {
    host         = var.host
    manifest_sha = sha256(local.root_app_manifest)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "2m"
  }

  provisioner "file" {
    content     = local.root_app_manifest
    destination = "/tmp/argo-root-app.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f /tmp/argo-root-app.yaml",
    ]
  }
}
