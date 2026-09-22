# Make sure to add this to your bookmarks: https://search.nixos.org/options
# This is where common options are set so you don't have to repeat yourself across files
{ settings, inputs, system, lib, config, isLive ? false, ... }: {
  imports = [
    ./modules/branding.nix
    ./modules/desktop/rice.nix
    ./modules/update.nix
  ] ++ lib.optional (!isLive) {
    home-manager.users.${settings.account.name} = {
      imports = [ ./modules/desktop/home-niri.nix ];
      programs.home-manager.enable = true;
      home.stateVersion = "25.05";
    };

    users.users.${settings.account.name} = {
      isNormalUser = true;
      extraGroups = lib.unique (
        [ "networkmanager" "wheel" ] ++ (settings.account.extraGroups or [ ])
      );
    }
    // lib.optionalAttrs (settings.account ? uid) {
      inherit (settings.account) uid;
    }
    // lib.optionalAttrs (settings.account ? home) {
      inherit (settings.account) home;
    }
    // lib.optionalAttrs (settings.account ? group) {
      inherit (settings.account) group;
    }
    # Migration deliberately leaves the password unspecified. With the NixOS
    # default `users.mutableUsers = true`, the existing /etc/shadow entry is
    # retained byte-for-byte rather than copied into the world-readable store.
    // lib.optionalAttrs (
      !(settings.account.preservePassword or false)
      && settings.account ? hashedPasswordFile
    ) {
      hashedPasswordFile = settings.account.hashedPasswordFile;
    }
    // lib.optionalAttrs (
      !(settings.account.preservePassword or false)
      && !(settings.account ? hashedPasswordFile)
    ) {
      # Non-installer builds remain locked unless explicitly configured.
      hashedPassword = settings.account.hashedPassword or "!";
    };

    systemd.services."home-manager-${settings.account.name}".serviceConfig = {
      StandardOutput = "journal";
      StandardError = "journal";
      TimeoutStartSec = lib.mkForce "15m";
    };
  };

  nixpkgs.hostPlatform = system;

  # Keep Home Manager activation predictable on both fresh installs and
  # systems where a desktop session has already created configuration files.
  # Verbose output is retained in the journal for actionable boot diagnostics.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit settings isLive; };
    backupFileExtension = "hm-backup";
    overwriteBackup = true;
    verbose = true;
  };

  networking.hostName = settings.hostName;
  system.stateVersion = "25.05";
  time.timeZone = settings.timeZone;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "@wheel" ];

  # /etc/umbra is the mutable, updater-managed Git checkout. Nix-generated
  # /etc entries there appear as untracked files and correctly trip the
  # updater's dirty-check, so keep all runtime material outside that namespace.
  assertions = [
    {
      assertion = lib.all
        (name: !(lib.hasPrefix "umbra/" name))
        (builtins.attrNames config.environment.etc);
      message = "environment.etc must not write inside the /etc/umbra Git checkout";
    }
  ];

  hardware.graphics.enable = true;

  # Guest agents are inert on physical hardware and activate only under their
  # matching hypervisor. Keep display resizing, clipboard integration, virtual
  # storage and clean shutdown working after installation as well as on the ISO.
  services.qemuGuest.enable = true;
  virtualisation.vmware.guest.enable = system == "x86_64-linux";

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

  /* Installed UEFI boot: Limine on x86, systemd-boot on ARM64. The live
     image disables both and uses the iso-image module's own EFI loader. */
  boot.loader.systemd-boot.enable = system == "aarch64-linux";
  boot.loader.limine = {
    enable = system == "x86_64-linux";
    efiSupport = true;
    # Install the standard EFI/BOOT/BOOTX64.EFI fallback. Some otherwise
    # UEFI-capable firmware exposes no BootOrder entry, which makes Limine's
    # efibootmgr registration path fail after the system has been copied.
    efiInstallAsRemovable = true;
    style.interface.branding = "UmbraOS";
  };
  # Avoid unreliable firmware NVRAM registration. The fallback loader is
  # written only to the EFI system partition selected by the installer.
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.efi.efiSysMountPoint = "/boot";
}
