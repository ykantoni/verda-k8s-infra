# Verda Cloud: Argo CD

This Terraform configuration installs [Argo CD](https://argo-cd.readthedocs.io/)
onto a cluster that already exists — via a real Terraform-managed
`helm_release` (the official `argo/argo-cd` chart), not a shell script, so
`plan` shows real diffs and `destroy` actually uninstalls it.

It's meant to be paired with the sibling
[`verda-vm-infra`](https://github.com/ykantoni/verda-vm-infra) repo, which
provisions the VMs *and* bootstraps RKE2 + Cilium onto them. The two are
applied independently — you can reinstall Argo CD without touching the
cluster, or recreate the cluster without needing to redesign how Argo CD
gets installed.

## Module structure

[`modules/argocd`](modules/argocd) does two things:

- `helm_release.argocd` — installs Argo CD itself. It takes no connection
  details of its own — the root module configures the `helm` provider and
  passes it in (`providers = { helm = helm }`), the same way any Terraform
  module receives a provider from its caller.
- `null_resource.root_app` — `kubectl apply`s one "app of apps" root
  `Application` over SSH (same pattern as the RKE2 bootstrap in
  `verda-vm-infra`), pointing Argo CD at this repo's [`argo-apps/`](argo-apps)
  directory. See below.

### How the `helm` provider finds the cluster

RKE2 bootstrap now lives entirely in `verda-vm-infra`, including fetching
a kubeconfig to a static local path there
(`verda-vm-infra/.terraform-kubeconfig.yaml`, gitignored). This repo's
`helm` provider ([versions.tf](versions.tf)) just points `config_path` at
that same file via a sibling-repo path — defaulting to
`../verda-vm-infra/.terraform-kubeconfig.yaml`, overridable with
`TF_VAR_kubeconfig_path` (same convention as `TF_VAR_tfstate_location`,
see below).

Since the two repos are applied independently, there's no Terraform-level
dependency enforcing order across them — `verda-vm-infra` has to actually
be applied first so that file exists, or `helm_release.argocd`'s plan will
fail trying to read it.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or newer, or [OpenTofu](https://opentofu.org).
- `verda-vm-infra` already applied (see its README) — this repo reads its
  kubeconfig file and, for `argocd_admin_password_command` only, its
  `cp1_ip` state output.

## 1. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

| Variable | Description | Default |
| --- | --- | --- |
| `ssh_user` | SSH user on the control-plane node (only for `argocd_admin_password_command`) | `root` |
| `ssh_private_key_path` | Private key matching the public key `verda-vm-infra` installed (only for `argocd_admin_password_command`) | `~/.ssh/id_ed25519` |
| `argocd_namespace` | Kubernetes namespace to install Argo CD into | `argocd` |
| `argocd_chart_version` | `argo-cd` Helm chart version (chart versioning tracks independently of the app version — 10.10.1 installs app v3.5.4) | `10.10.1` |
| `argo_apps_git_repo_url` | Git repo the app-of-apps root `Application` watches | `https://github.com/ykantoni/verda-k8s-infra.git` |
| `argo_apps_git_revision` | Git revision (branch, tag, or `HEAD`) it tracks | `HEAD` |
| `argo_apps_path` | Path within that repo containing child `Application` manifests | `argo-apps` |
| `tfstate_location` | Path to `verda-vm-infra`'s `terraform.tfstate`, read for `cp1_ip`. Set via `TF_VAR_tfstate_location` (the Justfile does this for you), not here | `../verda-vm-infra/terraform.tfstate` |
| `kubeconfig_path` | Path to the kubeconfig `verda-vm-infra` generates. Set via `TF_VAR_kubeconfig_path` (the Justfile does this for you), not here | `../verda-vm-infra/.terraform-kubeconfig.yaml` |

## 2. Deploy

From the `verda-cloud` root:

```bash
just k8s-init
just k8s-apply
```

(Or, inside this directory directly: `terraform init && terraform plan &&
terraform apply` — but then `tfstate_location`/`kubeconfig_path` fall back
to their plain relative defaults instead of the Justfile's computed
absolute paths, so make sure those still resolve correctly for your
checkout, or export `TF_VAR_tfstate_location`/`TF_VAR_kubeconfig_path`
yourself first.)

## 3. Access Argo CD

Argo CD's `argocd-server` is a `ClusterIP` service — not exposed outside
the cluster by default. Get the initial admin password (username `admin`):

```bash
eval "$(terraform output -raw argocd_admin_password_command)"
```

Then reach the UI/API either by tunneling through SSH:

```bash
ssh -L 8080:localhost:8080 root@<cp1-ip> \
  kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n argocd port-forward svc/argocd-server 8080:443
# then open https://localhost:8080
```

or by patching the service to `NodePort`/`LoadBalancer` if you want it
reachable without a tunnel (RKE2's bundled `servicelb`, in `verda-vm-infra`,
will bind a `LoadBalancer` service directly to a node's public IP):

```bash
kubectl --kubeconfig ~/verda_kubeconfig.yaml -n argocd patch svc argocd-server -p '{"spec": {"type": "LoadBalancer"}}'
```

(`~/verda_kubeconfig.yaml` comes from `just generate` in `verda-vm-infra` —
see that repo's README.)

## 4. argo-apps: GitOps-managed add-ons

[`argo-apps/`](argo-apps) holds Argo CD `Application` manifests. The root
"app of apps" (`null_resource.root_app`, applied once during `k8s-apply`)
points Argo CD at this directory with `recurse: true` and automated
sync/prune/self-heal — so adding, editing or removing a file here and
pushing it is enough; no `terraform apply` needed per app. Currently:

- **[`nvidia-gpu-operator.yaml`](argo-apps/nvidia-gpu-operator.yaml)** —
  NVIDIA GPU Operator (driver + container toolkit), namespace
  `gpu-operator`. These VMs are CPU-only instance types by default, so the
  driver/toolkit DaemonSets will sit idle with nothing to attach to until
  a GPU-equipped node actually joins the cluster — that's expected, not a
  failure.
- **[`openbao.yaml`](argo-apps/openbao.yaml)** — [OpenBao](https://openbao.org/)
  (open-source Vault fork) in **standalone** mode (not HA — with only 2
  nodes, Raft HA would need quorum from both on every write, i.e. zero
  fault tolerance, so standalone is the better fit here), namespace
  `openbao`. Helm/Argo CD can install it, but **cannot initialize or
  unseal it** — that's a deliberate manual step:

  ```bash
  ssh root@<cp1-ip> kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n openbao exec -it openbao-0 -- bao operator init
  # save the unseal keys and root token it prints, then:
  ssh root@<cp1-ip> kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n openbao exec -it openbao-0 -- bao operator unseal
  ```

- **[`external-secrets.yaml`](argo-apps/external-secrets.yaml)** — [External
  Secrets Operator](https://external-secrets.io/), namespace
  `external-secrets`. Installed with chart defaults (CRDs included); it
  does nothing until you create a `SecretStore`/`ClusterSecretStore`
  pointing it at a backend (e.g. the OpenBao instance above, once
  unsealed) and an `ExternalSecret` referencing it — neither is created
  here, since that needs real auth configured against an already-unsealed
  OpenBao.

## 5. Clean up

From the `verda-cloud` root:

```bash
just k8s-destroy
```

Argo CD (`helm_release.argocd`) is a real Terraform-managed resource, so
this properly uninstalls it (`helm uninstall` under the hood). Destroying
the VMs themselves (`just vm-destroy` in `verda-vm-infra`, or
`just destroy` for both repos in order) removes everything at once
regardless.

## Troubleshooting

- **`helm_release.argocd` fails with a connection error (`dial tcp ...
  connect: connection refused`, `no such host`, or similar):** The `helm`
  provider couldn't read the kubeconfig at `kubeconfig_path`, or it's
  stale/empty. Confirm `verda-vm-infra` has actually been applied
  (`just vm-apply`) — it's the one that generates that file — and that
  `kubeconfig_path` points at the right location
  (`echo $TF_VAR_kubeconfig_path`, or the default sibling path).
- **Argo CD pods stuck `Pending`/`ContainerCreating`/`ImagePullBackOff`
  after a successful apply:** Check directly:

  ```bash
  ssh root@<cp1-ip> kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n argocd get pods
  ```

  The `helm_release` doesn't wait on Cilium pods being `Ready` — if the
  CNI is still coming up when Argo CD's pods get scheduled, they'll sit
  `Pending`/`ContainerCreating` until it does; no action needed, just wait
  and re-check.
- **`Error: Unsupported attribute ... no attribute named "cp1_ip"`:**
  Only affects `argocd_admin_password_command`. `verda-vm-infra` hasn't
  been applied yet (its state has no outputs) — run `just vm-apply` from
  the `verda-cloud` root first.
- **`Error: Unable to find remote state` / no such file reading the
  remote state:** Same cause as above, but more literal — nothing exists
  at `tfstate_location` at all.
