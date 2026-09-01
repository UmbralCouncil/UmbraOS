{ inputs, lib, pkgs, settings, isLive ? false, ... }: let
    # Bring in the unstable channel
    unstable = import inputs.nixpkgs-unstable { inherit (pkgs) system; };
    umbraStudio = pkgs.callPackage ../studio/package.nix {
      coreRunner = inputs.self.nixosConfigurations.umbra-core-lab.config.microvm.declaredRunner;
    };
    commonPackages = with pkgs; [
      # Use the prefix 'unstable.' for unstable packages
      firefox
    ];
    installedPackages = [ umbraStudio ] ++ commonPackages;
in {
  # Persistent installs keep these in the user's Home Manager profile. The
  # ephemeral live account has no writable profile, so expose them system-wide.
  config = lib.mkMerge [
    {
      # Studio is proprietary; keep the exception narrow so other unfree
      # packages are not silently admitted into UmbraOS.
      nixpkgs.config.allowUnfreePredicate = pkg:
        lib.getName pkg == "umbra-studio-bin";
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
