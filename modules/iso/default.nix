{ lib, pkgs, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-graphical-base.nix"
    ../desktop/niri.nix
  ];

    # --- ISO compression ------------------------------------------------------
    isoImage.squashfsCompression = "zstd -Xcompression-level 15";

    # --- Networking: iwd ------------------------------------------------------
    networking.wireless.iwd.enable = true;
    networking.networkmanager.wifi.backend = "iwd";

    # --- Portable live-media boot ---------------------------------------------
    virtualisation.hypervGuest.enable = lib.mkForce false;
    services.xe-guest-utilities.enable = lib.mkForce false;

    # --- Audio ---------------------------------------------------------------
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = pkgs.stdenv.hostPlatform.isx86_64;
      pulse.enable = true;
      jack.enable = true;
    };

}
