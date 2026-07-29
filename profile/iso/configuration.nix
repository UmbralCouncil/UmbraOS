{ inputs, pkgs, lib, config, ... }:
let
  # Build the live rice independently from the NixOS Home Manager module. The
  # ephemeral `nixos` account must not gain a Home Manager systemd service:
  # activation expects a persistent user profile, which the live image does not
  # have. tmpfiles installs this immutable generation before login instead.
  riceHome = (inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ../../modules/desktop/home-rice.nix
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
  liveHyprlandConfig = pkgs.writeText "umbra-live.conf" ''
    exec-once = ${umbraInstaller}/bin/umbra-installer
  '';

in
{
  imports = [
    # The graphical Hyprland live/installer base and the live desktop come from
    # ../../modules/iso (wired into the umbra-live flake output). Umbra replaces
    # the base profile's installer flow with its own local web UI and constrained
    # Rust backend. This profile only layers the Umbra-specific live-session UX
    # and shared tooling on top; it must not re-import the graphical base or
    # ../../modules/desktop/hyprland.nix because the ISO module owns it.
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
    "d /home/nixos/.config 0755 nixos users - -"
    "d /home/nixos/.config/hypr 0755 nixos users - -"
    "d /home/nixos/.config/kitty 0755 nixos users - -"
    "d /home/nixos/.config/mako 0755 nixos users - -"
    "d /home/nixos/.config/waybar 0755 nixos users - -"
    "d /home/nixos/.config/wofi 0755 nixos users - -"
    "d /home/nixos/.config/gtk-3.0 0755 nixos users - -"
    "d /home/nixos/.config/gtk-4.0 0755 nixos users - -"
    "L+ /home/nixos/.config/hypr/hyprland.conf - nixos users - ${riceHome}/home-files/.config/hypr/hyprland.conf"
    "L+ /home/nixos/.config/hypr/hyprpaper.conf - nixos users - ${riceHome}/home-files/.config/hypr/hyprpaper.conf"
    "L+ /home/nixos/.config/hypr/hyprlock.conf - nixos users - ${riceHome}/home-files/.config/hypr/hyprlock.conf"
    "L+ /home/nixos/.config/hypr/live.conf - nixos users - ${liveHyprlandConfig}"
    "L+ /home/nixos/.config/kitty/kitty.conf - nixos users - ${riceHome}/home-files/.config/kitty/kitty.conf"
    "L+ /home/nixos/.config/mako/config - nixos users - ${riceHome}/home-files/.config/mako/config"
    "L+ /home/nixos/.config/waybar/config.jsonc - nixos users - ${riceHome}/home-files/.config/waybar/config.jsonc"
    "L+ /home/nixos/.config/waybar/style.css - nixos users - ${riceHome}/home-files/.config/waybar/style.css"
    "L+ /home/nixos/.config/wofi/config - nixos users - ${riceHome}/home-files/.config/wofi/config"
    "L+ /home/nixos/.config/wofi/style.css - nixos users - ${riceHome}/home-files/.config/wofi/style.css"
    "L+ /home/nixos/.config/gtk-3.0/settings.ini - nixos users - ${riceHome}/home-files/.config/gtk-3.0/settings.ini"
    "L+ /home/nixos/.config/gtk-4.0/settings.ini - nixos users - ${riceHome}/home-files/.config/gtk-4.0/settings.ini"
  ];

  system.activationScripts.installerDesktop = ''
    install -d -m 0755 -o nixos -g users /home/nixos/Desktop
    ln -sfT ${umbraInstaller}/share/applications/umbra-installer.desktop \
      /home/nixos/Desktop/umbra-installer.desktop
    chown -h nixos:users /home/nixos/Desktop/umbra-installer.desktop
  '';

  # Umbra Installer is the sole supported OS installer. A constrained native
  # Qt WebEngine window hosts the frontend; privileged operations remain in the
  # Rust Unix-socket backend.
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
