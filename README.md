# Verda Cloud: RKE2 Kubernetes bootstrap

This Terraform configuration installs and joins a 2-node
[RKE2](https://docs.rke2.io/) Kubernetes cluster — one control-plane node,
one worker — onto VMs that already exist. It does **not** create any VMs
itself: it connects over SSH to IPs read from `verda-vm-infra`'s state and
runs the RKE2 installer there.

It's meant to be paired with the sibling
[`verda-vm-infra`](https://github.com/ykantoni/verda-vm-infra) repo, which
provisions the VMs on [Verda Cloud](https://verda.com). The two are applied
independently — you can destroy and re-bootstrap the Kubernetes layer
without touching the VMs, or recreate the VMs without needing to redesign
how Kubernetes gets installed.

## What this does

- Generates one shared join token (`random_password.rke2_token`).
- Connects to the control-plane IP over SSH and runs the RKE2 server
  installer (`get.rke2.io`), configured with that token.
- Connects to the worker IP over SSH and runs the RKE2 agent installer,
  configured to join the control plane's `:9345` with the same token.
- Re-runs a node's install only when its target host or the rendered
  script changes (new token, new RKE2 version, or the IP changed because
  the underlying VM was replaced) — a no-op re-apply does nothing.

## Module structure

[`modules/rke2`](modules/rke2) takes a `role` (`server` or `agent`), a
shared `token`, and a `host` to SSH into, and renders + executes the
matching install script there via a `null_resource` with `file` and
`remote-exec` provisioners. It creates no cloud resources — it only acts on
a VM that's already running.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or newer, or [OpenTofu](https://opentofu.org).
- Two running VMs reachable over SSH as `root` (e.g. from `verda-vm-infra`), with the matching private key available locally.
- `ssh` and `scp`-capable connectivity between this machine and both VMs (the `file`/`remote-exec` provisioners use it under the hood).

## 1. Apply verda-vm-infra first

This repo reads the control-plane and worker IPs directly out of
`verda-vm-infra`'s Terraform state (`data "terraform_remote_state" "vm"` in
[main.tf](main.tf)) — there's nothing to copy by hand, provided you use the
root [Justfile](../Justfile) (`just vm-apply`, see `verda-vm-infra`'s
README), which also points this repo at the right state file for you via
`TF_VAR_tfstate_location`.

If a VM in `verda-vm-infra` is ever replaced and gets a new IP, just re-run
`just k8s-apply` — the new IP is picked up automatically, no
`terraform.tfvars` edit needed.

## 2. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

| Variable | Description | Default |
| --- | --- | --- |
| `ssh_user` | SSH user on both VMs | `root` |
| `ssh_private_key_path` | Private key matching the public key installed on the VMs | `~/.ssh/id_ed25519` |
| `rke2_version` | RKE2 version to install | `v1.37.1+rke2r1` |
| `tfstate_location` | Path to verda-vm-infra's `terraform.tfstate`. Set via `TF_VAR_tfstate_location` (the Justfile does this for you), not here | `../verda-vm-infra/terraform.tfstate` |

## 3. Deploy

From the `verda-cloud` root:

```bash
just k8s-init
just k8s-apply
```

(Or, inside this directory directly: `terraform init && terraform plan &&
terraform apply` — but then `tfstate_location` falls back to its plain
relative default instead of the Justfile's computed absolute path, so make
sure that still resolves correctly for your checkout, or export
`TF_VAR_tfstate_location` yourself first.)

Unlike a boot-time startup script, this blocks until each install finishes
over SSH — when `apply` completes, RKE2 is already installed and the
services are started. Give the Canal CNI pods a little longer to come up
before nodes show `Ready`.

## 4. Connect to the cluster from outside Verda Cloud

```bash
just k8s-config
```

This writes `~/kubeconfig.yaml` — in your home directory, regardless of
which directory you ran it from — rewriting the server address from
`127.0.0.1` to the control-plane's public IP. Its TLS certificate already
includes that IP (the install script sets `tls-san`), so no
`--insecure-skip-tls-verify` is needed:

```bash
kubectl --kubeconfig ~/kubeconfig.yaml get nodes
```

You should see both nodes `Ready` within a minute or so. Point any
kubectl-compatible tool (k9s, Lens, Helm, CI pipelines) at
`~/kubeconfig.yaml`, or merge it into `~/.kube/config`.

The API server (`terraform output api_server_url`) listens on `:6443` and
is reachable the same way from anywhere with network access to the IP —
the kubeconfig isn't tied to the machine that generated it.

### Reach apps running in the cluster

- **NodePort**: a `Service` of type `NodePort` is reachable at
  `<cp1 or worker1 ip>:<30000-32767>`.
- **Ingress**: RKE2 ships `rke2-ingress-nginx` by default, exposed through
  its own `NodePort` (check with
  `kubectl get svc -n kube-system rke2-ingress-nginx-controller`); point a
  DNS record or `/etc/hosts` entry at either node's IP and that port.
- **LoadBalancer**: RKE2's bundled `servicelb` (Klipper) binds
  `LoadBalancer` services directly to ports 80/443/etc. on every node's
  public IP — no external load balancer needed for a two-node cluster like
  this one.

### Lock it down (optional)

Verda has no cloud-level firewall, so restrict inbound traffic with `ufw`
on each node to your own IP range once you're done experimenting, e.g. on
`cp1`:

```bash
ssh root@<cp1-ip> '
  ufw allow from <your-ip>/32 to any port 22,6443 proto tcp
  ufw allow 10250/tcp                      # kubelet, node-to-node
  ufw allow 9345/tcp                       # RKE2 supervisor, node-to-node
  ufw allow 8472/udp                       # Canal VXLAN, node-to-node
  ufw default deny incoming
  ufw --force enable
'
```

Open additional ports (NodePort range, 80/443) only as needed, and repeat
with the equivalent rules on `worker1` (skip the `6443` rule there).

## 5. Clean up

From the `verda-cloud` root:

```bash
just k8s-destroy
```

This only removes Terraform's bootstrap bookkeeping (the `null_resource`s)
from state — it does **not** uninstall RKE2 from the VMs, since that was a
one-off remote command, not a resource Terraform manages the lifecycle of.
To actually remove Kubernetes from a node:

```bash
ssh root@<ip> /usr/local/bin/rke2-uninstall.sh   # or rke2-agent-uninstall.sh on the worker
```

Destroying the VMs themselves (`just vm-destroy`, or `just destroy` for
both repos in order) removes everything at once, uninstall script or not.

## Troubleshooting

- **`apply` hangs or times out connecting:** Confirm the VM is actually up
  and SSH-reachable: `ssh -i <key> root@<ip>`. The `connection` block
  retries for 5 minutes, so a VM still booting will eventually succeed —
  but a wrong IP, wrong key, or a `ufw` rule blocking your IP will not.
- **Node stuck `NotReady` or `kubectl` can't connect:** SSH in and check
  the install log and service status:

  ```bash
  ssh root@<ip> tail -n 100 /var/log/rke2-install.log
  ssh root@<ip> journalctl -u rke2-server -f   # on cp1
  ssh root@<ip> journalctl -u rke2-agent -f    # on worker1
  ```

- **Worker never joins:** Confirm the control-plane IP actually points at a
  running `rke2-server` and that the worker can reach it on `:9345` (not
  just `:22`) — a `ufw` rule on `cp1` that only opens `22` and `6443` would
  block this. Since the target host and rendered script haven't changed, a
  plain re-apply won't retry it — force it with (from this directory):
  `terraform apply -replace=module.rke2_agent.null_resource.bootstrap`.
- **A VM was replaced and got a new IP:** Just re-run `just k8s-apply` —
  the IP comes from `verda-vm-infra`'s state on every plan, and it's part
  of each module's trigger, so Terraform picks up the new address and
  reruns the install automatically.
- **`Error: Unsupported attribute ... no attribute named "cp1_ip"`:**
  `verda-vm-infra` hasn't been applied yet (its state has no outputs) —
  run `just vm-apply` from the `verda-cloud` root first.
- **`Error: Unable to find remote state` / no such file reading the remote
  state:** `tfstate_location` isn't pointed at the right file — nothing
  exists there at all. If you ran `terraform apply` directly instead of
  `just k8s-apply`, use the Justfile instead, or export
  `TF_VAR_tfstate_location` yourself to the real path first.
- **`remote-exec provisioner error ... Process exited with status 22`:**
  This is `curl`'s own exit code for an HTTP failure (`--fail`), surfacing
  from inside `get.rke2.io`'s install script — check
  `ssh root@<ip> tail -n 60 /var/log/rke2-install.log` for the actual URL
  that 404'd. If it's
  `.../releases/download/stable/sha256sum-amd64.txt`, that means
  `rke2_version` was left empty and the install script's "resolve the
  stable channel" call to `update.rke2.io/v1-release/channels/stable` came
  back 404 — an upstream RKE2 outage, not this repo. `rke2_version`
  defaults to a pinned tag specifically to avoid depending on that
  endpoint; if you've overridden it to `""`, un-override it, or set it to
  another concrete tag from
  `https://github.com/rancher/rke2/releases`.
