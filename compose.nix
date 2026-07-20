# Make sure to add this to your bookmarks: https://search.nixos.org/options
# This is where common options are set so you don't have to repeat yourself across files
{ settings, inputs, system, lib, ... }: {
  # Use Lix from nixpkgs rather than the lix-module's own pinned 2.92 source
  # build: that source sets `separateDebugInfo` together with
  # `disallowedReferences` but without `__structuredAttrs`, which nixpkgs
  # 26.05's stdenv rejects at eval time (and the throwing derivation can't be
  # `overrideAttrs`-patched). nixpkgs' packaged Lix is guard-compliant.
  imports = [ inputs.lix-module.nixosModules.lixFromNixpkgs ];

  nixpkgs.hostPlatform = system;

  networking.hostName = "nixos";
  system.stateVersion = "25.05";
  time.timeZone = settings.timeZone;

  home-manager.users.${settings.account.name} = {
    programs.home-manager.enable = true;
    home.stateVersion = "25.05";
  };

  users.users.${settings.account.name} = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" ];
    # Default login password is "umbra" (SHA-512 crypt). Change this before any
    # non-lab deployment — it is a well-known default, like other security
    # distros ship.
    hashedPassword = "$6$89mU305uYn2drBI4$8JuEj/ky8FJRlxzCs8Orb05i6rswJIxNaiNdg21o51s7qrO9VMF4/j8bWhvAnD.xDEiEYiBIe7VGHYquhEx42/";
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "@wheel" ];

  hardware.graphics.enable = true;

  /* Compressed memory */
  services.zram-generator.enable = true;

  /* Filesystems — UmbraOS targets Btrfs. Btrfs is already in the default
     supportedFilesystems set; ZFS is only pulled in by the NixOS installer CD
     base (nixpkgs profiles/base.nix sets `zfs = mkDefault true`), which drags in
     the ZFS kernel modules and the boot.zfs.forceImportRoot warning. We don't
     use ZFS, so drop it here for every host. */
  boot.supportedFilesystems.zfs = lib.mkForce false;

  /* Network */
  networking.firewall.enable = true;
  networking.networkmanager.enable = true;
  # services.openssh.enable = true;

  /* Bootloader — Limine (UEFI). The `iso` profile force-disables this because
     the live image supplies its own boot mechanism via the iso-image module. */
  boot.loader.systemd-boot.enable = false;
  boot.loader.limine = {
    enable = true;
    efiSupport = true;
    style.interface.branding = "UmbraOS";
  };
  boot.loader.efi.efiSysMountPoint = "/boot";
}
