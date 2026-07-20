# Declarative catalog of Umbra lab base images.
#
# There are two load-bearing image *classes*. Do NOT flatten them into one
# list anywhere:
#
#   bundled     — freely redistributable. Fetched at build time and seeded
#                 onto the ISO. Exposes a Nix derivation at `.drv`.
#   provisioned — NOT redistributable. The user fetches it from the vendor at
#                 runtime. NO derivation is produced; the image is expected at
#                 /var/lib/umbra/images/<name>.<format>.
#
# `sha256` is always the hash of the artifact at `url` (i.e. the archive when
# `archive` is set, not the unwrapped disk). `archive` tells the consumer that
# `url` is wrapped and must be extracted to obtain the `<format>` disk before
# use — without it, verifying then renaming a .zip to <name>.qcow2 yields a
# disk that will not boot.
#
# Umbra Studio (not this layer, and not a CLI) owns VM lifecycle and runtime
# provisioning. This module only *declares* images and, for bundled ones,
# pins and builds them. Per-lab service configuration (e.g. Samba for an SMB
# target) belongs in the lab layer, not here.
{ lib, pkgs, config, ... }:
let
  inherit (lib) mkOption types mapAttrs mapAttrsToList filterAttrs attrNames;

  cfg = config.umbra.labs;

  # A bundled image is the upstream disk fetched under a stable <name>.<format>
  # store name, unwrapped if it arrives inside an archive. Today every bundled
  # source is a bare qcow2, so the unzip branch is unused but kept honest.
  mkBundledDrv = name: img:
    let
      fetched = pkgs.fetchurl {
        inherit (img) url sha256;
        name = "${name}.${img.format}";
      };
    in
    if img.archive == null then
      fetched
    else
      pkgs.runCommand "${name}.${img.format}" { nativeBuildInputs = [ pkgs.unzip ]; } ''
        unzip -j ${fetched} -d extracted
        mv extracted/*.${img.format} "$out"
      '';

  # One JSON record per image. Class-shaped: `store_path` only for bundled,
  # `url`/`install_path`/`license_note` only for provisioned, and the archive
  # pair only when the source is wrapped — so Studio can branch on field
  # presence alone. `license_note` is provisioned-only: bundled images are
  # freely redistributable and carry no note (emitting it as null on bundled
  # would break the branch-on-presence contract).
  mkEntry = name: img:
    {
      inherit name;
      inherit (img) class format description sha256;
    }
    // lib.optionalAttrs (img.class == "bundled") {
      # img.drv is a fetchurl/runCommand output whose out path IS the disk
      # file, not a directory — safe to hand straight to the supervisor.
      store_path = "${img.drv}";
    }
    // lib.optionalAttrs (img.class == "provisioned") {
      inherit (img) url;
      install_path = "/var/lib/umbra/images/${name}.${img.format}";
      license_note = img.licenseNote;
    }
    // lib.optionalAttrs (img.archive != null) {
      inherit (img) archive;
      extracted_sha256 = img.extractedSha256;
    };

  catalogValue = {
    schema = 1;
    images = mapAttrsToList mkEntry cfg.images;
  };

  imagesJson = (pkgs.formats.json { }).generate "umbra-images.json" catalogValue;

  imageOpts = { name, config, ... }: {
    options = {
      class = mkOption {
        type = types.enum [ "bundled" "provisioned" ];
        description = "Redistribution class; decides whether Nix fetches the image.";
      };
      url = mkOption {
        type = types.str;
        description = "Upstream source URL (the artifact `sha256` hashes).";
      };
      sha256 = mkOption {
        type = types.str;
        description = "Pinned hash of the artifact at `url`. Required for both classes.";
      };
      format = mkOption {
        type = types.enum [ "qcow2" "raw" ];
        description = "On-disk image container format of the (unwrapped) disk.";
      };
      archive = mkOption {
        type = types.nullOr (types.enum [ "zip" ]);
        default = null;
        description = "If set, `url` is an archive that must be extracted to get the disk.";
      };
      extractedSha256 = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Hash of the disk AFTER unwrapping. Required when `archive` is set:
          `sha256` then covers only the downloaded archive, and this covers the
          disk the supervisor actually boots. Null for un-archived images.
        '';
      };
      description = mkOption {
        type = types.str;
        description = "Human-readable summary of the image.";
      };
      licenseNote = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Required for provisioned images; null for bundled.";
      };
      drv = mkOption {
        type = types.nullOr types.package;
        readOnly = true;
        description = "Built image derivation — bundled only; null when provisioned.";
      };
    };
    config = {
      drv = if config.class == "bundled" then mkBundledDrv name config else null;
    };
  };
in
{
  options.umbra.labs = {
    images = mkOption {
      type = types.attrsOf (types.submodule imageOpts);
      default = { };
      description = "Catalog of lab base images, keyed by name.";
    };

    bundledDrvs = mkOption {
      type = types.attrsOf types.package;
      readOnly = true;
      description = "Read-only map: bundled image name -> built derivation.";
    };

    provisionedNames = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      description = "Read-only list of provisioned (user-fetched) image names.";
    };

    catalog = mkOption {
      type = types.attrs;
      readOnly = true;
      internal = true;
      description = "Structured form of images.json (introspection; serialized to /etc/umbra/images.json).";
    };
  };

  config = {
    # --- Aggregates (kept strictly separate per class) --------------------
    umbra.labs.bundledDrvs =
      mapAttrs (_: img: img.drv)
        (filterAttrs (_: img: img.class == "bundled") cfg.images);

    umbra.labs.provisionedNames =
      attrNames (filterAttrs (_: img: img.class == "provisioned") cfg.images);

    umbra.labs.catalog = catalogValue;

    # --- Release gate: no placeholder hashes may ship ---------------------
    # Once images.json exists a placeholder hash is an exported claim Studio
    # acts on, so this fails `nix flake check` with a named, actionable error.
    assertions =
      (mapAttrsToList (name: img: {
        assertion = img.sha256 != lib.fakeHash;
        message =
          "umbra.labs.images.${name}: sha256 is still lib.fakeHash — pin a real hash before release.";
      }) cfg.images)
      ++ (mapAttrsToList (name: img: {
        assertion = img.extractedSha256 == null || img.extractedSha256 != lib.fakeHash;
        message =
          "umbra.labs.images.${name}: extracted_sha256 is still lib.fakeHash — pin a real hash before release.";
      }) cfg.images)
      ++ (mapAttrsToList (name: img: {
        assertion = img.archive == null || img.extractedSha256 != null;
        message =
          "umbra.labs.images.${name}: archive is set but extracted_sha256 is null — post-unwrap verification is required for archived images.";
      }) cfg.images);

    # --- Catalog export: the sole Nix -> Studio interface -----------------
    # Studio reads this; it must never parse Nix.
    environment.etc."umbra/images.json".source = imagesJson;

    # Provisioned images are dropped here by the user at runtime.
    systemd.tmpfiles.rules = [ "d /var/lib/umbra/images 0755 root root - -" ];

    # --- Catalog ----------------------------------------------------------
    # Versions are pinned to point releases, NOT rolling `latest`/`latest-stable`
    # symlinks, so a respin upstream doesn't silently break the pinned hash.
    umbra.labs.images = {
      debian-lab = {
        class = "bundled";
        # Dated serial dir, not .../trixie/latest/. Set to the real released
        # serial whose hash you pin.
        url = "https://cloud.debian.org/images/cloud/trixie/20260712-2537/debian-13-genericcloud-amd64-20260712-2537.qcow2";
        sha256 = "sha256-LKsWLd67HvCDzKj4Jh93yTrnD5glKqv+sdiijDCxkbE=";
        format = "qcow2";
        description = "Debian 13 (trixie) generic cloud image — general-purpose lab box.";
      };

      alpine-lab = {
        class = "bundled";
        # Versioned path (v3.21 / 3.21.7), not .../latest-stable/.
        url = "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/generic_alpine-3.21.7-x86_64-bios-cloudinit-r0.qcow2";
        sha256 = "sha256-PudDk5p3Up0vFnuVP2s19oOLf0zXeJg3rb6SOGUFbHQ=";
        format = "qcow2";
        description = "Alpine Linux official virt/cloud image — minimal lab box.";
      };

      routeros = {
        class = "provisioned";
        # MikroTik serves the disk inside a zip; `archive` makes that explicit
        # so Studio unwraps before renaming into install_path. MikroTik ships
        # no qcow2 — the wrapped disk is a raw `.img` (hence format = "raw").
        url = "https://download.mikrotik.com/routeros/7.20/chr-7.20.img.zip";
        sha256 = "sha256-0vaFl/EkFf81CTkJFSq3Vn6ByX0u77GkZYvsuPgrg7A="; # hash of the .zip (downloaded artifact)
        extractedSha256 = "sha256-O5iFH3m2jJlo8iatVOuy94yO1Rcy+yCTcwiyf4/72O4="; # hash of the unwrapped .img
        format = "raw";
        archive = "zip";
        description = "MikroTik RouterOS CHR — router/firewall lab node.";
        licenseNote = "MikroTik CHR is licensed for use, not redistribution. You must download it yourself from MikroTik.";
      };
    };
  };
}
