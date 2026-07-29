{ pkgs, ... }:
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
  # Keep the desktop close to a conventional Hyprland installation: the
  # compositor supplies the session, greetd handles login, and small standalone
  # tools provide the bar, launcher, notifications, wallpaper, and lock screen.
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  # SDDM runs its greeter on X11, then starts the native Hyprland Wayland
  # session. The theme is the pinned KDE Breeze theme with Umbra artwork.
  services.xserver.enable = true;
  services.xserver.excludePackages = [ pkgs.xterm ];
  services.displayManager = {
    defaultSession = "hyprland";
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
    grim
    hypridle
    hyprlock
    hyprpaper
    hyprpolkitagent
    kitty
    libnotify
    mako
    networkmanagerapplet
    pavucontrol
    pcmanfm
    slurp
    waybar
    wl-clipboard
    wofi
  ];

  security.polkit.enable = true;
  services.gnome.gnome-keyring.enable = true;

  # Audio
  security.rtkit.enable = true;
  services.pipewire.enable = true;
  services.pipewire.alsa.enable = true;
  services.pipewire.alsa.support32Bit = true;
  services.pipewire.pulse.enable = true;
  services.pipewire.jack.enable = true;

  # Boot screen, take out to see systemd logs.
  boot.plymouth.enable = true;
}
