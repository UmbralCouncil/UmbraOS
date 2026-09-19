{ config, lib, pkgs, isLive ? false, ... }:
let
  updater = import ../updater { inherit pkgs; };
in {
  config = lib.mkIf (!isLive) {
    environment.systemPackages = [ updater ];

    systemd.services.umbra-update = {
      description = "UmbraOS constrained system update service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      # The Rust backend uses absolute paths for its direct Git and rebuild
      # calls. nixos-rebuild is itself a script, however, and resolves Git,
      # Nix, and standard utilities through PATH while evaluating a flake.
      path = [ pkgs.coreutils pkgs.git pkgs.nix pkgs.nixos-rebuild ];
      serviceConfig = {
        ExecStart = "${updater}/bin/umbra-update-backend";
        Restart = "on-failure";
        RuntimeDirectory = "umbra-update";
        RuntimeDirectoryMode = "0755";
        StateDirectory = "umbra-update";
        StateDirectoryMode = "0700";
        UMask = "0007";
      };
    };
  };
}
