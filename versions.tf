terraform {
  required_version = ">= 1.5"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# Points at the kubeconfig verda-vm-infra generates (its
# null_resource.fetch_kubeconfig), since RKE2 bootstrap now lives there —
# this repo only installs Argo CD onto whatever cluster that file points
# at. Defaults to the sibling path; override with TF_VAR_kubeconfig_path if
# your checkout isn't laid out that way (same convention as
# tfstate_location). The path itself is a static string, known at plan
# time, even though the file's content only exists once verda-vm-infra has
# actually been applied.
provider "helm" {
  kubernetes = {
    config_path = coalesce(var.kubeconfig_path, "${path.module}/../verda-vm-infra/.terraform-kubeconfig.yaml")
  }
}
