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
[main.tf](main.tf), pointed at `../verda-vm-infra/terraform.tfstate`) — there's
nothing to copy by hand. That means:

- `verda-vm-infra` must be applied first, with its state at that relative
  path — i.e. both repos checked out as sibling directories (true under the
  `verda-cloud` submodule layout this project uses).
- If a VM in `verda-vm-infra` is ever replaced and gets a new IP, just
  re-run `terraform apply` here — the new IP is picked up automatically,
  no `terraform.tfvars` edit needed.

## 2. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

| Variable | Description | Default |
| --- | --- | --- |
| `ssh_user` | SSH user on both VMs | `root` |
| `ssh_private_key_path` | Private key matching the public key installed on the VMs | `~/.ssh/id_ed25519` |
| `rke2_version` | RKE2 version, e.g. `v1.31.4+rke2r1`. Empty installs the latest stable | `""` |

## 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

Unlike a boot-time startup script, this blocks until each install finishes
over SSH — when `apply` completes, RKE2 is already installed and the
services are started. Give the Canal CNI pods a little longer to come up
before nodes show `Ready`.

## 4. Connect to the cluster from outside Verda Cloud

Pull a working kubeconfig — this rewrites the server address from
`127.0.0.1` to the control-plane's public IP, and its TLS certificate
already includes that IP (the install script sets `tls-san`), so no
`--insecure-skip-tls-verify` is needed:

```bash
eval "$(terraform output -raw kubeconfig_command)"
kubectl --kubeconfig kubeconfig.yaml get nodes
```

You should see both nodes `Ready` within a minute or so. Point any
kubectl-compatible tool (k9s, Lens, Helm, CI pipelines) at
`kubeconfig.yaml`, or merge it into `~/.kube/config`.

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

`terraform destroy` here only removes Terraform's bootstrap bookkeeping
(the `null_resource`s) from state — it does **not** uninstall RKE2 from the
VMs, since that was a one-off remote command, not a resource Terraform
manages the lifecycle of. To actually remove Kubernetes from a node:

```bash
ssh root@<ip> /usr/local/bin/rke2-uninstall.sh   # or rke2-agent-uninstall.sh on the worker
```

Destroying the VMs themselves (in `verda-vm-infra`) removes everything at
once, uninstall script or not.

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
  plain re-apply won't retry it — force it with:
  `terraform apply -replace=module.rke2_agent.null_resource.bootstrap`.
- **A VM was replaced and got a new IP:** Just re-run `terraform apply` —
  the IP comes from `verda-vm-infra`'s state on every plan, and it's part
  of each module's trigger, so Terraform picks up the new address and
  reruns the install automatically.
- **`Error: Unsupported attribute ... no attribute named "cp1_ip"`:**
  `verda-vm-infra` hasn't been applied yet (its state has no outputs), or
  its `terraform.tfstate` isn't where this repo expects
  (`../verda-vm-infra/terraform.tfstate`, relative to this directory).
  Apply `verda-vm-infra` first, or fix the sibling checkout.
- **`Error: ... no such file or directory` reading the remote state:**
  Same cause as above, but `verda-vm-infra` hasn't even been `init`'d/applied
  once yet — its state file doesn't exist at all.
