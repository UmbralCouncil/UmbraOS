{ inputs, lib, pkgs, ... }:
{
  imports = [ inputs.silentSDDM.nixosModules.default ];

  programs.niri.enable = true;

  programs.silentSDDM = {
    enable = true;
    theme = "default";
    backgrounds.umbra = ../../assets/splash.png;
    settings = {
      LoginScreen = {
        background = "splash.png";
        background-fill-mode = "fill";
      };
      LockScreen = {
        background = "splash.png";
        background-fill-mode = "fill";
      };
    };
  };

  services.xserver.enable = true;
  services.xserver.excludePackages = [ pkgs.xterm ];
  services.displayManager.defaultSession = lib.mkForce "niri";

  environment.systemPackages = with pkgs; [
    adwaita-icon-theme
    gnome-terminal
    kitty
    libnotify
    mako
    networkmanagerapplet
    niri
    orca
    pavucontrol
    pcmanfm
    polkit_gnome
    swaybg
    swaylock-effects
    waybar
    wl-clipboard
    wofi
    xwayland-satellite
  ];

  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  security.polkit.enable = true;
  services.gnome.gnome-keyring.enable = true;
  services.gnome.at-spi2-core.enable = true;

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = pkgs.stdenv.hostPlatform.isx86_64;
    pulse.enable = true;
    jack.enable = true;
  };

  boot.plymouth.enable = true;
}
