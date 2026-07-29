{ inputs, lib, pkgs, settings, isLive ? false, ... }: let
    # Bring in the unstable channel
    unstable = import inputs.nixpkgs-unstable { inherit (pkgs) system; };
    packages = with pkgs; [
      # Use the prefix 'unstable.' for unstable packages
      git
      htop
      glib
      glibc
      # vim
    ];
in {
  # Persistent installs keep these in the user's Home Manager profile. The
  # ephemeral live account has no writable profile, so expose them system-wide.
  config = lib.mkMerge [
    (lib.mkIf (!isLive) {
      home-manager.users.${settings.account.name}.home.packages = packages;
    })
    (lib.mkIf isLive {
      environment.systemPackages = packages;
    })
  ];
  # Please see https://search.nixos.org/packages to see which packages are available
}
