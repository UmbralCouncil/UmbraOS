{ inputs, lib, pkgs, settings, isLive ? false, ... }: let
    unstable = import inputs.nixpkgs-unstable { inherit (pkgs) system; };
    packages = with pkgs; [
      git
      glib
      glibc
      nano
      vim
    ];
in {
  config = lib.mkMerge [
    (lib.mkIf (!isLive) {
      home-manager.users.${settings.account.name}.home.packages = packages;
    })
    (lib.mkIf isLive {
      environment.systemPackages = packages;
    })
  ];
}
