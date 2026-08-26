{ inputs, pkgs, lib, config, ... }:
let
  # Build only the live shell independently from the NixOS Home Manager module. The
  # ephemeral `nixos` account must not gain a Home Manager systemd service:
  # activation expects a persistent user profile, which the live image does not
  # have. tmpfiles installs this immutable generation before login instead.
  shellHome = (inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = {
      settings = null;
      isLive = true;
    };
    modules = [
      ../../modules/commands/shell.nix
      {
        home = {
          username = "nixos";
          homeDirectory = "/home/nixos";
          stateVersion = "25.05";
        };
        programs.home-manager.enable = true;
      }
    ];
  }).activationPackage;
  umbraInstaller = import ../../installer {
    inherit pkgs;
    source = inputs.self;
    flakeInputs = inputs;
  };
  umbraInstallerAutostart = pkgs.makeAutostartItem {
    name = "umbra-installer";
    package = umbraInstaller;
  };
in
{
  imports = [
    # The graphical Plasma live/installer base and desktop come from
    # ../../modules/iso (wired into the umbra-live flake output). Umbra replaces
    # the base profile's installer flow with its own native GUI and constrained
    # Rust backend. This profile only layers the Umbra-specific live-session UX
    # and shared tooling on top; it must not re-import the graphical base or
    # ../../modules/desktop/kde.nix because the ISO module owns it.
    ../../modules/apps/software.nix
    ../../modules/commands/software.nix
    ../../modules/commands/shell.nix
    ../../modules/virt/core.nix
  ];

  # The installed system uses Limine, but the ISO boots via the iso-image
  # module's own boot mechanism; make sure the disk bootloader isn't pulled in.
  boot.loader.limine.enable = lib.mkForce false;

  # SDDM starts the disposable live account directly; installed systems retain
  # the same Breeze-based login manager without autologin.
  services.displayManager.autoLogin = {
    enable = true;
    user = "nixos";
  };

  # The upstream graphical installer profile makes wheel passwordless. Retain
  # wheel membership for normal desktop integration, but do not grant the live
  # account an unrestricted root shell. Its sole passwordless privilege is the
  # installer backend, whose command modes, socket, token, and target validation
  # are enforced internally.
  security.sudo.wheelNeedsPassword = lib.mkForce true;
  security.sudo.extraRules = [
    {
      users = [ "nixos" ];
      commands = [
        {
          command = "${umbraInstaller}/libexec/umbra-installer/backend";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  systemd.tmpfiles.rules = [
    # The live profile consumes Home Manager's generated files without running
    # its activation script, so create the XDG directory tree explicitly.
    "d /home/nixos/Desktop 0755 nixos users - -"
    "d /home/nixos/Downloads 0755 nixos users - -"
    "d /home/nixos/Templates 0755 nixos users - -"
    "d /home/nixos/Public 0755 nixos users - -"
    "d /home/nixos/Documents 0755 nixos users - -"
    "d /home/nixos/Music 0755 nixos users - -"
    "d /home/nixos/Pictures 0755 nixos users - -"
    "d /home/nixos/Videos 0755 nixos users - -"
    "L+ /home/nixos/.zshrc - nixos users - ${shellHome}/home-files/.zshrc"
  ];

  system.activationScripts.installerDesktop = ''
    install -d -m 0755 -o nixos -g users /home/nixos/Desktop
    ln -sfT ${umbraInstaller}/share/applications/umbra-installer.desktop \
      /home/nixos/Desktop/umbra-installer.desktop
    chown -h nixos:users /home/nixos/Desktop/umbra-installer.desktop
  '';

  # Umbra Installer is the sole supported OS installer. A native eframe/egui
  # frontend talks directly to the constrained Rust Unix-socket backend;
  # privileged operations never run in the GUI process.
  environment.systemPackages = with pkgs; [
    umbraInstaller
    umbraInstallerAutostart
    git
    parted
    gptfdisk
  ];

  # ISO identity. Name the image via the modern `image.baseName` rather than the
  # deprecated `isoImage.isoName`: that alias now only feeds `image.fileName`,
  # while the actual on-disk filename (and `image.filePath`) derive from
  # `image.baseName` — setting `isoName` alone desyncs the advertised path from
  # the real file. `baseName` is extension-less; `.iso` is appended downstream.
  image.baseName = lib.mkForce
    "UmbraOS-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
  # This label is the initrd's live-media locator. It must remain distinct
  # from every label the installer writes to target disks.
  isoImage.volumeID = lib.mkForce "UMBRALIVE";
  isoImage.edition = "umbra";
  isoImage.appendToMenuLabel = " UmbraOS Live";
}
