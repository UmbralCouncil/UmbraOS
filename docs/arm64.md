# ARM64 / generic UEFI

UmbraOS and Umbra Studio expose separate native `aarch64-linux` outputs. These
target generic ARM64 UEFI machines and ARM virtual machines. They do not supply
Raspberry Pi board firmware or Apple Silicon boot integration.

## Build targets

Run on an ARM64 Linux builder, or an x86 host configured with a remote ARM64
Nix builder or AArch64 binfmt emulation. Selecting an ARM output does not
automatically cross-compile it or configure emulation.

```sh
# UmbraOS repository
nix build .#packages.aarch64-linux.iso -o result-arm64
nix build .#packages.aarch64-linux.installer -o result-installer-arm64
nix build .#checks.aarch64-linux.images-schema

# Private UmbraStudio repository
nix build .#packages.aarch64-linux.default -o result-arm64
nix build .#packages.aarch64-linux.release-bundle -o result-bundle-arm64
nix build .#packages.aarch64-linux.umbra-lab-vm -o result-lab-arm64
```

On an ARM builder, `nix build .#iso` in UmbraOS and `nix build .#release-bundle`
in UmbraStudio select the ARM package automatically. Existing x86 package
targets and configuration aliases remain available.

UmbraOS configuration names:

| Configuration | Purpose |
| --- | --- |
| `umbra-live-arm64` | UEFI live installer ISO |
| `umbra-arm64` | Generic installed system using `UMBRA_ROOT` / `UMBRA_EFI` labels |
| `umbra-core-lab-arm64` | ARM64 Umbra Core microVM |

The graphical installer records its native system in `installer-settings.nix`.
Its generated hardware configuration and `nixosConfigurations.default` then
use that architecture. Installed ARM systems use systemd-boot; x86 systems keep
Limine. The live ISO uses NixOS's EFI ISO bootloader.

## Studio release prerequisite

The ARM64 archive name is `umbra-studio-aarch64-linux.tar.zst`. Studio's private
release workflow builds x86 and ARM artifacts on separate native runners and
checks each executable's ELF architecture before uploading artifacts.

**The first ARM Studio release has not been published or hash-pinned yet.**
`modules/studio/package.nix` currently has `lib.fakeHash` for ARM. BEEFCAKE
replaces it automatically after building, auditing, publishing, and downloading
both Studio archives to verify their hashes. For a manual release, pin each
archive's verified SRI hash yourself. An ARM
persistent installation containing Studio cannot complete until this is done.
The live ISO does not contain Studio, matching the existing x86 live profile.

For private pre-release system builds, a NixOS module may supply an already
built, source-free archive instead:

```nix
umbra.studio.releaseArchive = /absolute/path/umbra-studio-aarch64-linux.tar.zst;
```

This must be the archive for the target architecture. Never put the private
Studio source repository into the public OS flake or ISO.

`tools/beefcake` builds and releases **both architectures in one run**. It uploads
the two Studio archives and checksums to GitHub, verifies both public downloads,
updates both OS pins, and then builds and uploads both ISOs and their checksums
to SourceForge. Each ISO filename includes `x86_64-linux` or `aarch64-linux`.
The standalone GitHub workflows remain available for artifact-only builds.

## Use your existing PC with ARM emulation

An additional ARM machine is optional. On your existing x86 NixOS host, add
this to **that host's configuration** and activate it using your normal host
rebuild command:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

This enables QEMU user-mode emulation and tells Nix it can execute ARM builds.
It is slower than a native ARM builder, but uses the same ARM package outputs
and available binary caches. It does not turn the generated binaries into x86
programs. Use your machine's actual configuration, not the repository's
development-hardware `nixosConfigurations.default`.

Then, from UmbraOS:

```sh
./tools/beefcake --check-builders
./tools/beefcake --jobs 1 --cores 2
```

The first command executes a small, fresh build for each architecture without
editing version files or contacting the release services. The second performs
the release with reduced local build parallelism. Adjust these limits for your
machine; they are not memory limits. No emulation or host configuration is
changed automatically by BEEFCAKE.

## usbproxy and Nix downloads

The `usbproxy` alias in your `.zshrc` exports lowercase `http_proxy` and
`https_proxy`. BEEFCAKE now inherits those variables automatically. An explicit
`--proxy 172.31.134.127:8228` sets both lowercase and uppercase proxy variables
for BEEFCAKE's client tools. The proxy is used by GitHub commands, public asset
verification, and the HTTP CONNECT tunnel for SourceForge SSH.

On this machine Nix uses the multi-user systemd daemon. That already-running
daemon cannot inherit variables from the shell where you run `usbproxy` or
BEEFCAKE. When a proxy is selected, BEEFCAKE asks for `sudo` once and installs
a temporary drop-in under `/run/systemd/system/nix-daemon.service.d`. It
restarts `nix-daemon`, keeps sudo authorization alive during long builds, and
removes the drop-in and restarts the daemon again whenever it exits. This
includes normal completion, errors, and terminal interruption. The proxy is
never written to `/etc/nixos` and also disappears on reboot if cleanup cannot
complete.

Use either your shell alias or the explicit option:

```sh
usbproxy
./tools/beefcake --check-builders

# Equivalent, without first running the alias:
./tools/beefcake --check-builders --proxy 172.31.134.127:8228
```

The runtime change affects other Nix commands using the same daemon while
BEEFCAKE runs. Avoid running an unrelated Nix download that should bypass the
proxy during a release. `--no-proxy` clears inherited proxy variables and does
not restart the daemon. BEEFCAKE restores any declarative or persistent daemon
environment after removing its temporary higher-priority drop-in.

## Android / Termux / UserLAnd

[Nix-on-Droid](https://github.com/nix-community/nix-on-droid) provides Nix on
64-bit ARM Android through PRoot without requiring root. It is a possible
environment to investigate for ARM builds, but the full Studio/ISO pipeline
has **not** been tested there. Plain Termux is not a drop-in Nix Linux builder;
UserLAnd would also need a working Nix environment. PRoot compatibility,
available memory/storage, and Android process management need validation on
the particular phone. BEEFCAKE currently always builds both architectures, so
running it on a phone would additionally require an x86 builder or emulation.
An Android SSH shell can also drive BEEFCAKE on your existing PC.

## Optional native ARM builder over SSH

For faster builds, use an ARM64 machine or ARM64 **Linux** VM with Nix installed
and reachable over SSH. NixOS is convenient; another Linux distribution with
a working Nix installation can also serve builds. A macOS Nix installation
by itself supplies `aarch64-darwin`, not the required `aarch64-linux` platform.

As a planning estimate, 8 CPU cores, 32 GiB RAM, and 200 GiB SSD space give useful
headroom for these builds; these are not measured minimum requirements. Smaller
machines can be tried with fewer concurrent jobs. The builder must be trusted
with the private Studio source that Nix sends to compile it.

Example module on a NixOS ARM builder, using your own public SSH key:

```nix
{ ... }: {
  services.openssh.enable = true;
  users.groups.nixbuilder = {};
  users.users.nixbuilder = {
    isSystemUser = true;
    group = "nixbuilder";
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [ "ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY" ];
  };
  nix.settings.trusted-users = [ "nixbuilder" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
```

Example module on your current NixOS host:

```nix
{ ... }: {
  nix.distributedBuilds = true;
  nix.settings.builders-use-substitutes = true;
  nix.buildMachines = [ {
    hostName = "arm-builder";
    system = "aarch64-linux";
    protocol = "ssh-ng";
    sshUser = "nixbuilder";
    sshKey = "/root/.ssh/umbra-arm-builder";
    maxJobs = 1;
    supportedFeatures = [ "big-parallel" ];
  } ];
}
```

The local Nix daemon, usually root, needs the private key and a verified SSH
host-key entry for the builder. Verify its fingerprint and test that account
before running BEEFCAKE. Only advertise `kvm` if the builder actually supports
it; the small builder probes do not certify VM boot tests or all build features.
Remote concurrency is controlled by `maxJobs`, not BEEFCAKE's local `--jobs`.

You can alternatively provide a builder list for one run:

```sh
./tools/beefcake --check-builders \
  --builders 'ssh-ng://nixbuilder@arm-builder aarch64-linux /root/.ssh/umbra-arm-builder 1 1 big-parallel'
```

`--builders` replaces Nix's configured remote builder list for that invocation;
omit it to keep using your normal configuration. `UMBRA_BUILDERS` provides the
same override as an environment variable.

References: [Nix remote builds](https://nix.dev/tutorials/nixos/distributed-builds-setup.html)
and [NixOS ARM emulation](https://wiki.nixos.org/wiki/NixOS_on_ARM).

## Runtime and validation limits

- The ARM catalog excludes the existing x86-only Debian, Alpine, and RouterOS
  disks. ARM courses/labs must provide native ARM package outputs and runners.
- The built-in Umbra Core runner is native ARM64. Hardware-accelerated labs
  require `/dev/kvm`; ARM VMs may need nested virtualization enabled.
- CPU and Vulkan AI runtime outputs exist for ARM. CUDA and ROCm package
  outputs remain x86-only; GPU inference still depends on guest/host drivers.
- Configuration evaluation is not a boot test. Validate the ISO in an ARM64
  UEFI VM with a graphical display, then test installation to a disposable
  disk and reboot before publishing it as a tested release.

The build workflow uses GitHub's
[ARM64 Linux runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
