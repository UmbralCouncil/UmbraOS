{ inputs, pkgs, lib, config, modulesPath, ... }:
let
  # The UmbraOS flake source itself, so it can be shipped on the ISO and
  # installed from the live session.
  flakeSrc = inputs.self;

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
