<p align="center">
  <img src="assets/umbraos_logo.png" width="300" alt="UmbraOS Logo">
</p>

> A reproducible security-training platform built around NixOS.

Umbra combines an open-source host operating system, a native learning
application, and an open course format to make hands-on security training
reproducible, approachable, and safe.

## The Umbra Platform

### UmbraOS

UmbraOS is the open-source NixOS host: a modular, reproducible alternative to
Kali without traditional dependency hell. Its system, desktop, installer, lab
infrastructure, and updates are expressed declaratively through Nix flakes.

### Umbra Studio

Umbra Studio is the native application where learners install courses, launch
labs, follow tasks, use an isolated terminal, and submit answers.

Every lab runs as its own headless QEMU/KVM microVM. Learners can have root
inside the guest without gaining access to the UmbraOS host, its files, or its
LAN.

### Umbra Course SDK

The open-source Umbra Course SDK lets third parties create and distribute
courses. A course is a Nix flake containing its manifest, lessons, tasks,
graders, fixtures, and microVM configuration. Studio installs that flake as a
self-contained training module.

## Open-core Model

- **UmbraOS** and the **Umbra Course SDK** are open source.
- **Umbra Learn/Education** remains free.
- **Umbra Studio Professional** is a $120 perpetual license.
- **Umbra Enterprise** is $500 annually, plus $50 per additional user.

## UmbraOS Today

- Bootable Niri live images for x86_64 and ARM64
- Native graphical installer with whole-disk and manual/dual-boot paths
- Local, Git-backed system updates with normal NixOS generations and rollback
- KVM/QEMU microVM host and isolated-guest infrastructure
- Declarative, schema-validated lab image and course registries
- Privacy-first operation with no mandatory telemetry

UmbraOS is under active development. Test installation changes on disposable
hardware or virtual machines before deploying them to important systems.

## ARM64 builds

Dedicated `aarch64-linux` targets support generic UEFI ARM machines and VMs:
`nix build .#packages.aarch64-linux.iso`. See [ARM64 build instructions](docs/arm64.md)
for Studio bundles, native builder requirements, and the first ARM release's
remaining publication and boot-validation steps.

## Migrating an Existing NixOS Host

Do not switch an existing machine directly to `.#default`: that output contains
the repository development machine's hardware configuration and the fresh
install account defaults.

The guarded migration helper generates a private flake snapshot using the
current machine's detected hardware and existing normal user. It leaves the
user's password unmanaged so NixOS retains the current `/etc/shadow` entry,
preserves the account UID, home, primary group, and supplementary groups, and
performs a build plus dry activation before changing the running system.

First validate without changing the system:

```console
nix run .#migrate -- --build
```

To switch display managers safely, move to a virtual console with
`Ctrl+Alt+F3`, log in, and run:

```console
nix run .#migrate -- --switch
```

The previous NixOS generation remains available. To revert:

```console
sudo nixos-rebuild switch --rollback
```

Each attempt is retained beneath `/var/lib/umbra/migrations`; a successful
switch also points `/etc/nixos/umbra` at the active migration snapshot.

## Join the Family

![Discord](https://discord.com/api/guilds/1527521057483784264/widget.png?style=banner2)
