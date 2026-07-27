{ inputs, pkgs, lib, config, ... }:
let
  # Home Manager is used only to build the immutable desktop-file generation.
  # The live account does not run Home Manager activation: that activation
  # expects a persistent, writable Nix profile, which an ephemeral ISO user
  # deliberately does not have. tmpfiles installs the generation before login.
  riceHome = config.home-manager.users.nixos.home.activationPackage;
  umbraInstaller = import ../../installer {
    inherit pkgs;
    source = inputs.self;
  };
  umbraInstallerAutostart = pkgs.makeAutostartItem {
    name = "umbra-installer";
    package = umbraInstaller;
  };

in
{
  imports = [
    # The graphical Plasma 6 live/installer base and the live desktop come from
    # ../../modules/iso (wired into the umbra-live flake output). That base ships
    # Calamares as UmbraOS's sole installation path. This profile only layers
    # the Umbra-specific live-session UX and shared tooling on top; it must not
    # re-import the graphical base or
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

  # The activation package above is a build-time source for `riceHome`.
  # Applying it through the normal Home Manager system service would attempt
  # to create a mutable per-user Nix profile on the read-only live system.
  systemd.services.home-manager-nixos.enable = false;

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

  system.activationScripts.installerDesktop = ''
    install -d -m 0755 -o nixos -g users /home/nixos/Desktop
    ln -sfT ${umbraInstaller}/share/applications/umbra-installer.desktop \
      /home/nixos/Desktop/umbra-installer.desktop
    chown -h nixos:users /home/nixos/Desktop/umbra-installer.desktop
  '';

  # Umbra Installer is the sole supported OS installer. Firefox is its local
  # HTML shell; the privileged backend is a fixed Bash API, not browser code.
  environment.systemPackages = with pkgs; [
    umbraInstaller
    umbraInstallerAutostart
    firefox
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
