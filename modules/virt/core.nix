# MicroVM HOST support (https://github.com/astro/microvm.nix).
#
# UmbraOS runs microVMs as disposable, air-gapped sandboxes for handling
# untrusted code and live malware. The host side therefore deliberately
# provides NO bridge, NO tap devices, NO NAT/DHCP — there is intentionally
# nothing for a guest to attach to.
#
# Per-guest isolation (no network, no host filesystem access) is enforced by
# ./isolated-guest.nix, which every lab VM declared under `microvm.vms.<name>`
# must import.
{ inputs, ... }: {
  imports = [ inputs.microvm.nixosModules.host ];

  # Install the microVM runners and systemd plumbing. This alone exposes
  # nothing to guests; it only lets this machine start them.
  microvm.host.enable = true;
}
