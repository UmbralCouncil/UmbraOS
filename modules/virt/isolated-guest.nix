# Isolation baseline for an UmbraOS analysis microVM.
#
# Import this into EVERY guest you declare (as a module inside
# `microvm.vms.<name>.config`). It is meant for running malware and other
# untrusted code, so the guarantee is: the VM can reach NOTHING on the host
# and has NO network path anywhere.
#
# Both properties are already the microvm.nix defaults (empty `interfaces`,
# empty `shares`); this module forces them so a lab module cannot loosen them
# by accident, and switches the guest to its own on-disk Nix store so it never
# reads from the host's /nix/store.
{ lib, ... }: {
  # --- No network, at all ---
  # microvm.nix only attaches a NIC if one is listed here. Force it empty.
  microvm.interfaces = lib.mkForce [ ];

  # Defence in depth: kill every in-guest network bring-up path too.
  networking.useNetworkd = lib.mkForce false;
  networking.useDHCP = lib.mkForce false;
  networking.dhcpcd.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  networking.firewall.enable = lib.mkForce true;

  # --- No host filesystem access ---
  # A guest only sees host paths that appear in `shares`; the host /nix/store
  # passthrough is opt-in, so keep shares empty and give the guest its own
  # store on disk instead of reaching into the host's.
  microvm.shares = lib.mkForce [ ];
  microvm.storeOnDisk = true;
}
