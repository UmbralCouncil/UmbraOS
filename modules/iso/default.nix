# UmbraOS live/installer ISO — the graphical Plasma 6 image users boot to try
# or install Umbra, and the vehicle that seeds the freely-redistributable lab
# base images onto the medium.
#
# This module OWNS the ISO's squashfs compression, the live desktop, and the
# lab-image seeding. It builds on nixpkgs' Plasma 6 graphical installer base and
# the umbra microVM `core` module so the live session can already host labs.
# The ISO name / volume ID are deliberately left to profile/iso/configuration.nix
# (which mkForces the UmbraOS identity); this module does not fight that.
#
# It deliberately does NOT import ../desktop/plasma.nix. That module enables
# SDDM, which collides with the Plasma 6 installer base's plasma-login-manager
# (a host may run only one display manager). The base already supplies the KDE
# desktop + login manager + autologin, so importing plasma.nix here would both
# duplicate the desktop and force a display-manager conflict. The one piece
# plasma.nix adds that the base lacks — the PipeWire audio stack — is reproduced
# below so the live session still has sound.
{ config, lib, pkgs, modulesPath, ... }:
let
  cfg = config.umbra.iso;
in
{
  imports = [
    # nixpkgs graphical Plasma 6 installer base (KDE + plasma-login-manager +
    # Calamares + autologin as `nixos`).
    "${modulesPath}/installer/cd-dvd/installation-cd-graphical-calamares-plasma6.nix"
    # umbra microVM host, so the live session can run labs out of the box.
    ../virt/core.nix
  ];

  options.umbra.iso = {
    maxSizeGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = ''
        Maximum built ISO size, in GiB. The image is USB-targeted, so this is a
        USB budget — there is intentionally no DVD-capacity check. Enforced when
        the ISO is actually built (see `system.build.umbraIsoSizeCheck`): the
        build fails with actual vs. allowed size.
      '';
    };

    # Read-only introspection so `nix eval …config.umbra.iso` is meaningful.
    maxSizeBytes = lib.mkOption {
      type = lib.types.ints.positive;
      readOnly = true;
      description = "maxSizeGiB expressed in bytes — the build-time size budget.";
    };
  };

  config = {
    umbra.iso.maxSizeBytes = cfg.maxSizeGiB * 1024 * 1024 * 1024;

    # --- ISO compression ------------------------------------------------------
    # (isoName / volumeID stay owned by profile/iso/configuration.nix.)
    isoImage.squashfsCompression = "zstd -Xcompression-level 15";

    # --- Networking: iwd ------------------------------------------------------
    # Wi-Fi via iwd. NetworkManager (from compose.nix) drives it through the iwd
    # backend rather than wpa_supplicant.
    networking.wireless.iwd.enable = true;
    networking.networkmanager.wifi.backend = "iwd";

    # --- Audio (the non-conflicting half of ../desktop/plasma.nix) ------------
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;
    };

    # --- Seed the redistributable lab base images onto the ISO ----------------
    # Only bundled drvs (debian-lab, alpine-lab) — provisioned images are
    # non-redistributable and must never be seeded (asserted below).
    system.extraDependencies = builtins.attrValues config.umbra.labs.bundledDrvs;

    # --- Invariant: no provisioned image may enter the ISO closure ------------
    # RouterOS (and any future provisioned image) is licensed for use, not
    # redistribution — it must never ship on a public ISO. The only way a
    # provisioned image could reach the closure is by acquiring a build
    # derivation (which `system.extraDependencies` or a store reference could
    # then pull in). A provisioned image must therefore have NO drv: assert that
    # for every provisioned image and name any offender loudly. This is what
    # keeps RouterOS off the public ISO.
    assertions = lib.mapAttrsToList
      (name: img: {
        assertion = img.drv == null;
        message =
          "umbra.iso: provisioned (non-redistributable) image '${name}' has a "
          + "build derivation (${toString img.drv}) and could enter the ISO "
          + "closure — provisioned images must never ship on a public ISO.";
      })
      (lib.filterAttrs (_: img: img.class == "provisioned") config.umbra.labs.images);

    # --- Size budget ----------------------------------------------------------
    # A single derivation that depends on the one ISO build and checks its size,
    # so it is reachable from `nix flake check` without building the ISO twice.
    # Fails loudly with actual vs. allowed size. USB budget only.
    system.build.umbraIsoSizeCheck =
      pkgs.runCommand "umbra-iso-size-check"
        {
          maxBytes = toString cfg.maxSizeBytes;
          maxGiB = toString cfg.maxSizeGiB;
        }
        ''
          # `filePath` (from the images framework passthru) is the exact emitted
          # path under the derivation, e.g. iso/umbra-….iso — more robust than
          # globbing and correct even if the image is compressed.
          iso="${config.system.build.images.iso}/${config.system.build.images.iso.passthru.filePath}"
          actual=$(stat -c%s "$iso")
          gib=$(awk "BEGIN{printf \"%.2f\", $actual/1073741824}")
          if [ "$actual" -gt "$maxBytes" ]; then
            echo "UmbraOS ISO is $actual bytes ($gib GiB), over the $maxGiB GiB budget." >&2
            exit 1
          fi
          echo "UmbraOS ISO OK: $actual bytes ($gib GiB) <= $maxGiB GiB."
          touch "$out"
        '';
  };
}
