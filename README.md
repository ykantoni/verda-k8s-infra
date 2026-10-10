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
| `argocd_service_type` | `argocd-server` Service type — `NodePort` to reach it directly, `ClusterIP` to only reach it via tunnel/your own Ingress | `NodePort` |
| `argocd_node_port_http` | NodePort for the HTTP port (redirects to HTTPS). Only used when `argocd_service_type = "NodePort"` | `30080` |
| `argocd_node_port_https` | NodePort for the HTTPS port. Only used when `argocd_service_type = "NodePort"` | `30443` |
| `tfstate_location` | Path to `verda-vm-infra`'s `terraform.tfstate`, read for `cp1_ip`. Set via `TF_VAR_tfstate_location` (the Justfile does this for you), not here | `../verda-vm-infra/terraform.tfstate` |
| `kubeconfig_path` | Path to the kubeconfig `verda-vm-infra` generates. Set via `TF_VAR_kubeconfig_path` (the Justfile does this for you), not here | `../verda-vm-infra/.terraform-kubeconfig.yaml` |

## 2. Deploy

From the `verda-cloud` root:

```bash
just k8s-init
just k8s-apply
```

`k8s-apply` does more than `terraform apply` now: right after, it also
runs `scripts/unseal-openbao.sh` (auto-init/unseal, same as `just unseal`)
and `scripts/configure-vllm-secret.sh` (wires OpenBao up as External
Secrets Operator's backend — see `vllm-secrets.yaml` below). Both are
idempotent and safe on every run, including ones where nothing changed.

(Or, inside this directory directly: `terraform init && terraform plan &&
terraform apply` — but then `tfstate_location`/`kubeconfig_path` fall back
to their plain relative defaults instead of the Justfile's computed
absolute paths, so make sure those still resolve correctly for your
checkout, or export `TF_VAR_tfstate_location`/`TF_VAR_kubeconfig_path`
yourself first; you'd also need to run the two scripts above yourself,
since this bypasses the Justfile entirely.)

## 3. Access Argo CD

`argocd-server`'s Service defaults to `NodePort` (`argocd_service_type`;
see the variable table above), bound to `30080`/`30443` on **every**
node's public IP — so it's reachable directly, no tunnel needed:

```bash
# https://<cp1-ip or worker1-ip>:30443
```

Get the initial admin password (username `admin`):

```bash
eval "$(terraform output -raw argocd_admin_password_command)"
```

If you set `argocd_service_type = "ClusterIP"` instead (e.g. to put it
behind your own Ingress), reach it via SSH tunnel:

```bash
ssh -L 8080:localhost:8080 root@<cp1-ip> \
  kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n argocd port-forward svc/argocd-server 8080:443
# then open https://localhost:8080
```

**Lock it down**: Verda has no cloud-level firewall (see `verda-vm-infra`'s
README), so `30080`/`30443` are open to the internet on both nodes by
default. If you've applied `ufw` rules there, add these two ports (or the
whole NodePort range `30000-32767`, since other `argo-apps` Services may
bind one too) for the IPs that should reach them.

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
  `openbao`. Its data volume is backed by Longhorn, which `verda-vm-infra`
  installs directly (via RKE2's own helm-controller, not Argo CD — see
  that repo's README) as part of the cluster bootstrap; if that was
  applied before Longhorn was added there, re-run `just vm-apply` to pick
  it up, or this pod sits `Pending` the same way anything else needing a
  `PersistentVolumeClaim` would. Helm/Argo CD can install OpenBao itself,
  but **cannot initialize or unseal it** itself. Helm/Argo CD never do
  this automatically; by default it's a manual step:

  ```bash
  ssh root@<cp1-ip> kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n openbao exec -it openbao-0 -- bao operator init
  # save the unseal keys and root token it prints, then run `bao operator
  # unseal` 3 times (threshold 3-of-5), each time pasting a different key
  # at the hidden prompt.
  ```

  OpenBao re-seals on every pod restart (standalone/file storage doesn't
  auto-unseal), and a fresh `PersistentVolumeClaim` (e.g. after the
  cluster or Longhorn volume is rebuilt) means a brand-new, never-`init`'d
  instance with no keys yet at all — re-running the same manual steps
  every time gets old fast for a lab. [`scripts/unseal-openbao.sh`](scripts/unseal-openbao.sh)
  (`just unseal` from the `verda-cloud` root) automates all of
  this: it waits for `openbao-0` to be `Running`; does nothing if already
  unsealed; if never initialized, runs `bao operator init` itself and
  **overwrites** `~/.openbao-unseal-keys` with the new keys (also printed
  to your terminal — back them up somewhere more durable too); then reads
  3 keys from that file (gitignored by virtue of living outside this repo
  entirely — one key per line, `#`-prefixed lines ignored) and runs the 3
  unseal calls. This is a deliberate trade-off: storing all the keys
  needed to unseal (and now auto-generating/auto-saving them with zero
  human review) defeats Shamir secret sharing's actual security property
  (no single place holds enough keys alone) in exchange for never having
  to do this by hand — reasonable for this lab, not for an instance
  holding secrets you actually need to protect from whoever has access
  to this machine (use a real auto-unseal, e.g. a Transit seal, for
  that).

  Its `server.service` is set to `NodePort`/`30092`, so once unsealed it's
  reachable directly at `http://<cp1-ip>:30092` — no tunnel needed. Root
  token: the one `scripts/unseal-openbao.sh` saved to
  `~/.openbao-unseal-keys` (see above). It also gets an `HTTPRoute`
  (`gateway-routes/openbao-httproute.yaml`, host `openbao.lab`) through
  the shared Gateway described below — a second, additive way to reach
  it at `http://openbao.lab:<port>/` instead of the NodePort (`just
  endpoints`, from the `verda-cloud` root, prints the actual port).

- **[`external-secrets.yaml`](argo-apps/external-secrets.yaml)** — [External
  Secrets Operator](https://external-secrets.io/), namespace
  `external-secrets`. Installed with chart defaults (CRDs included). Its
  first real backend — OpenBao, via a `SecretStore`/`ExternalSecret` — is
  wired up by `vllm-secrets.yaml` below, for the vLLM app's Hugging Face
  token specifically; nothing else uses it yet.
- **[`kube-prometheus-stack.yaml`](argo-apps/kube-prometheus-stack.yaml)** —
  Prometheus + Grafana (plus Alertmanager, node-exporter and
  kube-state-metrics), namespace `monitoring`. One chart rather than two
  separate ones, specifically so Grafana comes pre-wired with that
  Prometheus as its datasource — installing them as independent apps
  would need a manual datasource-config step afterward. Installed with
  chart defaults: no persistent storage for either Prometheus or Grafana
  (data is lost on pod restart — fine for exploring, not for anything you
  need to keep). Both `prometheus.service` and `grafana.service` are set
  to `NodePort` (`30090`/`30091`), reachable directly — no tunnel needed:

  ```bash
  # http://<cp1-ip>:30090  (Prometheus)
  # http://<cp1-ip>:30091  (Grafana, username: admin)
  ssh root@<cp1-ip> kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
  ```

  (A port-forward works too if you'd rather not expose the NodePort —
  substitute `kubectl port-forward` the same way the OpenBao entry above
  describes.) Grafana and Prometheus also each get an `HTTPRoute`
  (`gateway-routes/monitoring-httproutes.yaml`, hosts `grafana.lab` /
  `prometheus.lab`) through the shared Gateway described below.

- **[`gateway-routes.yaml`](argo-apps/gateway-routes.yaml)** — unlike the
  apps above, this points Argo CD at a **directory** of plain manifests
  in this same repo ([`gateway-routes/`](gateway-routes)) rather than an
  external Helm chart, since `HTTPRoute`s aren't a Helm chart install.
  It holds the OpenBao and Grafana/Prometheus `HTTPRoute`s mentioned
  above, each attached to the single shared `Gateway`
  (`lab-gateway`, namespace `kube-system`) that `verda-vm-infra` creates
  as part of its RKE2 bootstrap (see that repo's README for the full
  Gateway API explanation — Cilium is the Gateway controller, no extra
  ingress controller needed). Longhorn's `HTTPRoute` lives over there
  too, next to Longhorn itself, since it isn't Argo CD-managed.

  This is purely additive — every NodePort documented above keeps
  working unchanged. The only new thing it adds is a second way to reach
  OpenBao/Grafana/Prometheus (and Longhorn's UI), all multiplexed by
  hostname through one shared NodePort Service instead of one NodePort
  each (it's a `NodePort`, not a `LoadBalancer`, because Verda terminates
  ports 80/443 on every VM's public IP at its own edge — see
  `verda-vm-infra`'s README for the full explanation and why the port
  number can't be pinned to a fixed value). Since Verda gives you a bare
  IP with no real DNS, add the hostnames to `/etc/hosts` yourself — see
  `verda-vm-infra`'s README for the exact line to add — and get the
  live port number from `just endpoints`.

- **[`vllm-secrets.yaml`](argo-apps/vllm-secrets.yaml)** — another
  plain-manifest directory Application (same pattern as
  `gateway-routes.yaml`), pointing at [`vllm-secrets/`](vllm-secrets):
  a `ServiceAccount` (`vllm`), a `SecretStore` pointing External Secrets
  Operator at OpenBao's in-cluster Service, and an `ExternalSecret` that
  turns OpenBao's `secret/vllm/hf-token` into a real `vllm-hf-token`
  Secret. No secret *values* live in any of these three files — the
  Hugging Face token itself only ever exists inside OpenBao and inside
  the Secret ESO materializes from it.

  The OpenBao-side half of this wiring (enabling its kv engine, enabling
  and configuring Kubernetes auth, writing the policy/role these files'
  `auth.kubernetes.role: vllm` depends on) isn't part of this
  Application — it's `scripts/configure-vllm-secret.sh`, which now runs
  automatically on every `just k8s-apply` (see "2. Deploy" above). The
  one piece that script can't automate is the actual Hugging Face token
  value: set `$HF_TOKEN` or save it to `~/.hf-token` first (after
  accepting Google's Gemma license and generating a READ-scoped token on
  Hugging Face) for it to get written; otherwise that step is skipped
  with a message and the `ExternalSecret` stays unresolved until you
  supply one and rerun `just configure-vllm-secret`.

- **[`vllm.yaml`](argo-apps/vllm.yaml)** — self-hosted
  [vLLM](https://docs.vllm.ai/), serving
  [`google/gemma-3n-E4B-it`](https://huggingface.co/google/gemma-3n-E4B-it)
  (~15.7GB checkpoint) via the official
  [`vllm-project/production-stack`](https://github.com/vllm-project/production-stack)
  chart, namespace `vllm`. Requires a GPU node — see `verda-vm-infra`'s
  README for `gpu1` (`create_gpu_node`, off by default); the pod stays
  `Pending` until one joins, same as `nvidia-gpu-operator` has been all
  along. Uses a 20Gi Longhorn-backed PVC for the model cache (per-model
  `pvcStorage`, chart-provisioned) and the `vllm-hf-token` Secret from
  `vllm-secrets.yaml` above. The chart's own router component is exposed
  as `NodePort` `30095` (pinned directly in the chart's values, unlike the
  Gateway's dynamically-assigned port — this chart supports a fixed
  `routerSpec.nodePort`):

  ```bash
  curl http://<any-node-ip>:30095/v1/models
  curl http://<any-node-ip>:30095/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "gemma-3n-e4b", "messages": [{"role": "user", "content": "Hello!"}]}'
  ```

  A few deliberate, documented-in-`vllm.yaml` deviations from the chart's
  own defaults, worth knowing if you ever touch this file: `tensorParallelSize`
  forced to `1` (the chart defaults to `2`, assuming multiple GPUs),
  `requestGPUType` forced to `nvidia.com/gpu` (the chart defaults to a
  MIG-sliced GPU type, which doesn't apply to a whole, unpartitioned
  A100), `keda.enabled` forced to `false` (KEDA isn't installed in this
  cluster — its CRDs don't exist), and `lmcacheConfig.enabled` forced to
  `false` (keeping this first deployment close to plain vLLM behavior).
  **Unverified**: this was written and YAML/chart-values-validated but
  never run against a real pod, since standing up the GPU node is a
  separate, explicit step you take yourself (see `verda-vm-infra`'s
  README) — if the model doesn't come up cleanly once a GPU node exists,
  start by checking the pod's logs for engine-selection or image-tag
  issues (`tag: "latest"` was used deliberately rather than guessing a
  specific version known to support Gemma 3n).

**All of the NodePorts above** (Argo CD, OpenBao, Prometheus, Grafana) plus
`verda-vm-infra`'s Longhorn UI NodePort can be listed in one shot, with the
current cluster's actual IP filled in, by running `just endpoints` from the
`verda-cloud` root. Same "Lock it down" caveat as Argo CD's section above
applies to all of them — Verda has no cloud-level firewall, so add `ufw`
rules for any of these ports you don't want open to the whole internet.

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

- **`external-secrets` Application stuck `OutOfSync`/`Degraded`, with
  `CustomResourceDefinition ... is invalid: metadata.annotations: Too long:
  may not be more than 262144 bytes` and pods (`external-secrets`,
  `external-secrets-cert-controller`) crash-looping or failing healthz with
  `no matches for kind "ClusterSecretStore"`/`"SecretStore"`:** The
  `SecretStore`/`ClusterSecretStore` CRDs in this chart are large enough
  that Argo CD's default client-side apply (storing the full manifest in a
  `last-applied-configuration` annotation) exceeds Kubernetes' 256 KiB
  annotation limit. `external-secrets.yaml` sets `ServerSideApply=true` to
  avoid this — if you're hitting it anyway, confirm that sync option is
  actually present on the live `Application` (`kubectl get application
  external-secrets -n argocd -o jsonpath='{.spec.syncPolicy.syncOptions}'`)
  and, if the CRDs are still missing, apply them directly once to unblock:

  ```bash
  curl -sSL https://raw.githubusercontent.com/external-secrets/external-secrets/v<chart-app-version>/deploy/crds/bundle.yaml \
    | kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply --server-side -f -
  kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n external-secrets rollout restart deployment external-secrets external-secrets-cert-controller
  ```

- **A `PersistentVolumeClaim` (e.g. `data-openbao-0`) stays `Pending`
  even after Longhorn is up** (check with
  `ssh root@<cp1-ip> kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -n longhorn-system`,
  see `verda-vm-infra`'s README): Kubernetes only assigns a default
  `StorageClass` to a PVC *when it's created* — a PVC created before
  Longhorn existed has `storageClassName: ""` baked in and will never
  retroactively adopt the new default. Delete the stuck PVC (and its
  pod, so the StatefulSet recreates both):

  ```bash
  ssh root@<cp1-ip> kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n openbao delete pod openbao-0 pvc data-openbao-0
  ```

  The pod comes back, creates a fresh PVC, and this time picks up
  Longhorn's default class.
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
