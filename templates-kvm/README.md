# Deploy multiple VMs from a golden image with kcli

Deploys several identical Oracle Linux 9 guest VMs on the KVM/libvirt host set up
by [`../install-kvm`](../install-kvm/). One golden OL9 cloud image is cloned into
`vm_count` copy-on-write VMs (cloned in seconds) and personalized on first boot by
cloud-init using [kcli](https://kcli.readthedocs.io/).

Scaling from 1 to N VMs is a single number (`vm_count`).

## What's here

```
templates-kvm/
  bootstrap.sh            # install kcli + download the golden "ol9" image (once)
  kcli_plan.yml           # basic plan: a Jinja loop that defines ol9-vm1..N
  kcli_parameters.yml     # tunables: vm_count, hardware, pool, network
  kcli_plan_advanced.yml  # advanced plan: custom network, dedicated pool, per-VM limits
  README.md
```

## Prerequisites

- KVM/libvirt already installed on the host (run [`../install-kvm`](../install-kvm/) first).
- The libvirt `default` NAT network is active (`virsh net-list --all`).
- Run everything **on the KVM host** as `opc` (already in the `libvirt` group from
  install-kvm step 05), so kcli talks to the local `qemu:///system`.
- The host has outbound internet to download the golden image once.

Copy this folder to the host and switch into it, for example:

```sh
scp -i ../terraform-linux-day1/generated/sau-linux-day1 -r ../templates-kvm opc@<public-ip>:~/
ssh -i ../terraform-linux-day1/generated/sau-linux-day1 opc@<public-ip>
cd ~/templates-kvm
```

## 1. Bootstrap (once)

Installs kcli from the `karmab/kcli` COPR repo and downloads the golden Oracle
Linux 9 KVM cloud image as the kcli image `ol9`, then verifies its SHA256. Safe
to re-run. The default image is `OL9U8_x86_64-kvm-b293.qcow2`, matching the OL 9.8
host.

```sh
./bootstrap.sh
```

To pin a different OL9 build, set `OL9_IMAGE_URL` (and the matching
`OL9_IMAGE_SHA256`, or `OL9_IMAGE_SHA256=` to skip verification) before running.
Get current URLs and checksums from
<https://yum.oracle.com/oracle-linux-templates.html>:

```sh
OL9_IMAGE_URL=https://yum.oracle.com/templates/OracleLinux/OL9/u8/x86_64/OL9U8_x86_64-kvm-b293.qcow2 \
OL9_IMAGE_SHA256=b12103391327abee8090686759c0d62dac9a7af2bf0f45fdf6b0d085a0fbb52b \
./bootstrap.sh
```

Confirm the image is registered:

```sh
kcli list image
```

## 2. Deploy the VMs

```sh
kcli create plan -f kcli_plan.yml templatevms
```

This creates `ol9-vm1 .. ol9-vm5` (the default `vm_count`) as thin clones of the
golden image. kcli injects your SSH public key and sets each hostname via
cloud-init.

## 3. Inspect and log in

```sh
kcli list vm            # wait a few seconds for the VMs to grab DHCP IPs
kcli info vm ol9-vm1
kcli ssh ol9-vm1        # key was auto-injected by cloud-init
```

## Scale up or down

Change the count at runtime (idempotent - re-running adjusts the set):

```sh
kcli create plan -f kcli_plan.yml -P vm_count=8 templatevms
```

Or edit `vm_count` in [`kcli_parameters.yml`](kcli_parameters.yml) and re-run
`kcli create plan`. Other hardware knobs (`numcpus`, `memory`, `disk_size`) and
the `pool`/`network` live in the same file.

## Tear down

```sh
kcli delete plan templatevms
```

## Advanced plan (custom network, dedicated pool, per-VM limits)

[`kcli_plan_advanced.yml`](kcli_plan_advanced.yml) is a self-contained plan (its
defaults live in an inline `parameters:` block) that layers on the features you
usually want in a real deployment:

- Custom NAT network `ol9net` (`10.99.0.0/24`) with its own DHCP range and DNS
  `domain` - set `nat: false` to make it isolated/host-only instead.
- Dedicated storage pool `ol9pool` that bounds where the VM clones live.
- Per-VM resource limits: fixed `numcpus`/`memory`, CPU pinning (each VM capped
  onto a distinct host core), `numamode`, and a size-capped extra data disk.
- Richer cloud-init: installs the qemu guest agent, formats/mounts the data disk
  at `/data`, and writes a custom `/etc/motd`; plus `autostart`, `nested`, `rng`,
  `uefi`, and `tags`.

kcli creates the pool directory as the calling user, so create it once with the
right ownership before the first run:

```sh
sudo install -d -o qemu -g qemu /var/lib/libvirt/ol9pool
```

Deploy, inspect, scale and tear down:

```sh
kcli create plan -f kcli_plan_advanced.yml advancedvms
kcli list vm && kcli ssh ol9-adv1
kcli create plan -f kcli_plan_advanced.yml -P vm_count=5 advancedvms   # scale
kcli delete plan advancedvms
```

Notes:

- `host_cpus` defaults to 4 to match the lab `VM.Standard.E5.Flex` (4 OCPU);
  pinning spreads VMs across host cores with `(num - 1) % host_cpus`. Set it to
  your host's real core count.
- The VMs use DHCP on the custom network. For static addressing, replace the
  `nets` entry with `{ name: ol9net, ip: 10.99.0.50, mask: 255.255.255.0,
  gateway: 10.99.0.1, dns: 10.99.0.1 }` (use IPs outside the DHCP range).
- kcli has no native hard-CPU-quota keyword; the pinning above is a soft cap. For
  a hard cap you would post-process with `virsh schedinfo <vm> --set vcpu_quota=...`.

## How it works

```
golden "ol9" image  ->  thin COW clone per VM  ->  cloud-init (SSH key + hostname + cmds)
```

- `kcli_plan.yml` is a Jinja template: the `{% for num in range(1, vm_count + 1) %}`
  loop stamps out one VM block per VM, all cloning `base_image`.
- `disks: [{ thin: true }]` makes each VM a copy-on-write overlay on the golden
  image instead of a full copy, so clones are fast and space-efficient.
- Oracle Linux is not a built-in kcli image alias, so `bootstrap.sh` registers it
  explicitly with `kcli download image -P url=<OL9 qcow2 URL> ol9`.

## Notes

- The golden image is x86_64 to match the lab's `VM.Standard.E5.Flex` shape. If the
  host is switched to an ARM shape (`A1.Flex`), point `OL9_IMAGE_URL` at an aarch64
  OL9 image and add `-P arch=aarch64` to the `kcli download image` call.
- Guests get DHCP addresses on the libvirt `default` NAT network and are reachable
  from the host; they are not directly public.
