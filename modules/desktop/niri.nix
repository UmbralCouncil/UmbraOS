{ lib, pkgs, ... }:
let
  umbraSddmTheme = pkgs.runCommand "umbra-breeze-sddm-theme" { } ''
    theme="$out/share/sddm/themes/umbra-breeze"
    mkdir -p "$(dirname "$theme")"
    cp -r ${pkgs.kdePackages.plasma-desktop}/share/sddm/themes/breeze "$theme"
    chmod -R u+w "$theme"
    substituteInPlace "$theme/theme.conf" \
      --replace-fail \
        'background=${pkgs.kdePackages.breeze}/share/wallpapers/Next/contents/images/5120x2880.png' \
        'background=${../../assets/splash.png}'
    substituteInPlace "$theme/metadata.desktop" \
      --replace-fail 'Name=Breeze' 'Name=Umbra Breeze' \
      --replace-fail 'Theme-Id=breeze' 'Theme-Id=umbra-breeze'
  '';
in
{
  programs.niri.enable = true;

  services.xserver.enable = true;
  services.xserver.excludePackages = [ pkgs.xterm ];
  services.displayManager = {
    defaultSession = lib.mkForce "niri";
    sddm = {
      enable = true;
      theme = "${umbraSddmTheme}/share/sddm/themes/umbra-breeze";
      extraPackages = [ pkgs.kdePackages.plasma-desktop ];
      settings.Theme = {
        CursorTheme = "Adwaita";
        CursorSize = 24;
      };
    };
  };

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

  security.polkit.enable = true;
  services.gnome.gnome-keyring.enable = true;
  services.gnome.at-spi2-core.enable = true;

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
