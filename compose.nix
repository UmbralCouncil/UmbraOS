# Make sure to add this to your bookmarks: https://search.nixos.org/options
# This is where common options are set so you don't have to repeat yourself across files
{ settings, inputs, system, lib, isLive ? false, ... }: {
  imports = [
    ./modules/branding.nix
    ./modules/desktop/rice.nix
  ] ++ lib.optional (!isLive) {
    home-manager.users.${settings.account.name} = {
      imports = [ ./modules/desktop/home-rice.nix ];
      programs.home-manager.enable = true;
      home.stateVersion = "25.05";
    };

    users.users.${settings.account.name} = {
      isNormalUser = true;
      extraGroups = [ "networkmanager" "wheel" ];
      # Default login password is "umbra" (SHA-512 crypt). Change this before
      # any non-lab deployment — it is a well-known default, like other
      # security distros ship.
      hashedPassword = settings.account.hashedPassword;
    };

    systemd.services."home-manager-${settings.account.name}".serviceConfig = {
      StandardOutput = "journal";
      StandardError = "journal";
      TimeoutStartSec = lib.mkForce "15m";
    };
  };

  nixpkgs.hostPlatform = system;

  # Keep Home Manager activation predictable on both fresh installs and
  # systems where Plasma has already created its own configuration files.
  # Verbose output is retained in the journal for actionable boot diagnostics.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    overwriteBackup = true;
    verbose = true;
  };

  networking.hostName = settings.hostName;
  system.stateVersion = "25.05";
  time.timeZone = settings.timeZone;

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
