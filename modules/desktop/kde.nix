{ pkgs, ... }:
{
  # Deliberately stock Plasma: no Umbra rice, generated dotfiles, custom SDDM
  # theme, or Hyprland utilities. This branch is the conventional desktop and
  # accessibility variant of the otherwise identical system.
  services.desktopManager.plasma6.enable = true;
  services.displayManager = {
    defaultSession = "plasma";
    sddm.enable = true;
  };

  services.xserver.enable = true;
  services.xserver.excludePackages = [ pkgs.xterm ];

  security.polkit.enable = true;

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  boot.plymouth.enable = true;
}
