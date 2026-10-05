{ inputs, lib, pkgs, settings, config, isLive ? false, ... }: let
    # Bring in the unstable channel
    unstable = import inputs.nixpkgs-unstable { inherit (pkgs) system; };
    umbraStudio = pkgs.callPackage ../studio/package.nix {
      releaseArchive = config.umbra.studio.releaseArchive;
      coreRunner = inputs.self.nixosConfigurations."umbra-core-lab-${pkgs.system}".config.microvm.declaredRunner;
      mistralCpuRunner = inputs.self.packages.${pkgs.system}.ai-runner-cpu;
      llamaVulkanRunner = inputs.self.packages.${pkgs.system}.ai-runner-vulkan;
    };
    umbraNote = pkgs.callPackage ../note/package.nix {
      releaseArchive = config.umbra.note.releaseArchive;
    };
    commonPackages = with pkgs; [
      # Use the prefix 'unstable.' for unstable packages
      librewolf
    ];
    installedPackages = [ umbraStudio umbraNote ] ++ commonPackages;
in {
  options.umbra.studio.releaseArchive = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = "Optional source-free Studio archive for this host architecture, used before publishing a release.";
  };
  options.umbra.note.releaseArchive = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = "Optional source-free Umbra Note archive for this host architecture, used before publishing a release.";
  };
  # Persistent installs keep these in the user's Home Manager profile. The
  # ephemeral live account has no writable profile, so expose them system-wide.
  config = lib.mkMerge [
    {
      # Studio is proprietary; keep the exception narrow so other unfree
      # packages are not silently admitted into UmbraOS.
      nixpkgs.config.allowUnfreePredicate = pkg:
        lib.getName pkg == "umbra-studio-bin";

      # Electron requires Chromium's privileged sandbox helper when user
      # namespaces are unavailable. NixOS installs and owns this setuid wrapper
      # at /run/wrappers/bin/__chromium-suid-sandbox.
      security.chromiumSuidSandbox.enable = true;
    }
    (lib.mkIf (!isLive) {
      # Studio launches unprivileged QEMU/KVM guests. Membership grants access
      # to /dev/kvm without granting host root.
      users.users.${settings.account.name}.extraGroups = [ "kvm" ];
      home-manager.users.${settings.account.name}.home.packages = installedPackages;
    })
    (lib.mkIf isLive {
      environment.systemPackages = commonPackages;
    })
  ];
  # Check https://search.nixos.org/packages to see which packages are available
}
