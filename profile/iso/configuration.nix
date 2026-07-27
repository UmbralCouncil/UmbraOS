{ inputs, pkgs, lib, config, modulesPath, ... }:
let
  # The UmbraOS flake source itself, so it can be shipped on the ISO and
  # installed from the live session.
  flakeSrc = inputs.self;
  # Home Manager remains the source of the desktop files, but a live account
  # must not depend on its activation service winning a race with auto-login.
  # tmpfiles links the same immutable generation into /home/nixos before the
  # graphical session starts.
  riceHome = config.home-manager.users.nixos.home.activationPackage;

  # Helper that installs UmbraOS from the copy of the flake on the ISO.
  umbra-install = pkgs.writeShellScriptBin "umbra-install" ''
    set -euo pipefail
    echo "== UmbraOS installer =="
    echo
    echo "1. Partition and mount your target disk at /mnt (use GParted or parted),"
    echo "   including the EFI system partition at /mnt/boot."
    echo "2. Generate hardware config for this machine:"
    echo "     sudo nixos-generate-config --root /mnt --no-filesystems"
    echo "   and copy the result into"
    echo "     /home/nixos/UmbraOS/profile/default/hardware.nix"
    echo
    read -rp "Have you mounted your target at /mnt? [y/N] " ok
    case "$ok" in
      y|Y) ;;
      *) echo "Aborting."; exit 1 ;;
    esac
    sudo nixos-install --flake /home/nixos/UmbraOS#default
  '';
in
{
  imports = [
    # The graphical Plasma 6 live/installer base and the live desktop come from
    # ../../modules/iso (wired into the umbra-live flake output). That base ships
    # Calamares alongside our own `umbra-install` flake installer, so users can
    # take either path. This profile only layers the umbra-specific installer UX
    # and the shared tooling on top; it must NOT re-import the graphical base or
    # ../../modules/desktop/plasma.nix — plasma.nix's SDDM collides with the
    # base's plasma-login-manager.
    ../../modules/apps/software.nix
    ../../modules/commands/software.nix
    ../../modules/commands/shell.nix
    ../../modules/virt/core.nix
  ];

  # The installed system uses Limine, but the ISO boots via the iso-image
  # module's own boot mechanism; make sure the disk bootloader isn't pulled in.
  boot.loader.limine.enable = lib.mkForce false;

  # Auto-login to the Plasma live session as the `nixos` installer user.
  services.displayManager.autoLogin = {
    enable = true;
    user = "nixos";
  };

  # The live desktop uses nixpkgs' `nixos` installer account rather than the
  # normal UmbraOS account configured in compose.nix.
  home-manager.users.nixos = {
    imports = [ ../../modules/desktop/home-rice.nix ];
    programs.home-manager.enable = true;
    home.stateVersion = "25.05";
  };

  systemd.tmpfiles.rules = [
    "d /home/nixos/.config 0755 nixos users - -"
    "d /home/nixos/.config/autostart 0755 nixos users - -"
    "d /home/nixos/.local/bin 0755 nixos users - -"
    "d /home/nixos/.local/share/color-schemes 0755 nixos users - -"
    "d /home/nixos/.local/share/icons/hicolor/scalable/apps 0755 nixos users - -"
    "d /home/nixos/.local/share/icons/hicolor/scalable/places 0755 nixos users - -"
    "d /home/nixos/.local/share/icons/hicolor/256x256/apps 0755 nixos users - -"
    "d /home/nixos/.local/share/wallpapers/UmbraOS/contents/images 0755 nixos users - -"
    "L+ /home/nixos/.config/kdeglobals - nixos users - ${riceHome}/home-files/.config/kdeglobals"
    "L+ /home/nixos/.config/autostart/umbra-rice.desktop - nixos users - ${riceHome}/home-files/.config/autostart/umbra-rice.desktop"
    "L+ /home/nixos/.local/bin/umbra-apply-rice - nixos users - ${riceHome}/home-files/.local/bin/umbra-apply-rice"
    "L+ /home/nixos/.local/share/color-schemes/UmbraDark.colors - nixos users - ${riceHome}/home-files/.local/share/color-schemes/UmbraDark.colors"
    "L+ /home/nixos/.local/share/color-schemes/UmbraLight.colors - nixos users - ${riceHome}/home-files/.local/share/color-schemes/UmbraLight.colors"
    "L+ /home/nixos/.local/share/icons/hicolor/256x256/apps/umbraos.png - nixos users - ${riceHome}/home-files/.local/share/icons/hicolor/256x256/apps/umbraos.png"
    "L+ /home/nixos/.local/share/icons/hicolor/scalable/apps/umbra-application-dark.svg - nixos users - ${riceHome}/home-files/.local/share/icons/hicolor/scalable/apps/umbra-application-dark.svg"
    "L+ /home/nixos/.local/share/icons/hicolor/scalable/apps/umbra-application-light.svg - nixos users - ${riceHome}/home-files/.local/share/icons/hicolor/scalable/apps/umbra-application-light.svg"
    "L+ /home/nixos/.local/share/icons/hicolor/scalable/places/start-here.svg - nixos users - ${riceHome}/home-files/.local/share/icons/hicolor/scalable/places/start-here.svg"
    "L+ /home/nixos/.local/share/icons/hicolor/scalable/places/start-here-kde-symbolic.svg - nixos users - ${riceHome}/home-files/.local/share/icons/hicolor/scalable/places/start-here-kde-symbolic.svg"
    "L+ /home/nixos/.local/share/wallpapers/UmbraOS/contents/images/2560x1600.png - nixos users - ${riceHome}/home-files/.local/share/wallpapers/UmbraOS/contents/images/2560x1600.png"
  ];

  # Ship the flake on the ISO (read-only at /UmbraOS) and drop a writable copy
  # in the live user's home so `umbra-install` / `nixos-install --flake` works.
  isoImage.contents = [
    { source = flakeSrc; target = "/UmbraOS"; }
  ];
  system.activationScripts.umbraFlake = ''
    if [ ! -e /home/nixos/UmbraOS ]; then
      mkdir -p /home/nixos
      cp -r ${flakeSrc} /home/nixos/UmbraOS
      chmod -R u+w /home/nixos/UmbraOS
      chown -R nixos:users /home/nixos/UmbraOS
    fi
  '';

  # Installer tooling available in the live session.
  environment.systemPackages = with pkgs; [
    umbra-install
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
  isoImage.volumeID = lib.mkForce "UMBRAOS";
  isoImage.edition = "umbra";
  isoImage.appendToMenuLabel = " UmbraOS Live";
}
