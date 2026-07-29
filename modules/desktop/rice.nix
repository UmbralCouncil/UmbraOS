{ lib, pkgs, ... }:
let
  umbraPlasmaTheme = import ./theme-package.nix { inherit pkgs; };
in
{
  environment.systemPackages = [ umbraPlasmaTheme ];

  # Keep the artwork in the system closure so boot and desktop components can
  # refer to the same immutable files.
  environment.etc = {
    "umbra/artwork/logo.png".source = ../../assets/logo.png;
    "umbra/artwork/splash.png".source = ../../assets/splash.png;
    "umbra/artwork/brandmark.png".source = ../../assets/umbraos_logo.png;
    "umbra/artwork/wallpaper.png".source = ../../assets/home_wallpaper.png;
    "umbra/artwork/palette.png".source = ../../assets/color_palette.png;
    "umbra/artwork/application-button-dark.svg".source =
      ../../assets/darkmode_application_button.svg;
    "umbra/artwork/application-button-light.svg".source =
      ../../assets/lightmode_application_button.svg;
    "umbra/artwork/install.png".source = ../../assets/install.png;
  };

  # Limine is used by installed UmbraOS systems. The ISO has its own boot path
  # and force-disables Limine, so these defaults naturally apply only where the
  # loader is active.
  boot.loader.limine.style = {
    wallpapers = [ ../../assets/splash.png ];
    wallpaperStyle = "stretched";
    backdrop = "000824";
    interface = {
      brandingColor = "2";
      helpColor = "7";
      helpColorBright = "15";
    };
  };

  # `bgrt` prefers firmware artwork and can therefore hide the configured
  # distro splash entirely. Breeze Plymouth is built with the dedicated Umbra
  # splash asset and always renders it during boot.
  boot.plymouth = {
    theme = "breeze";
    logo = ../../assets/splash.png;
  };

  # Let desktop shells and About dialogs resolve UmbraOS's own mark through
  # the standard freedesktop icon name advertised by os-release.
  environment.etc."xdg/icons/hicolor/256x256/apps/umbraos.png".source =
    ../../assets/logo.png;

  assertions = [
    {
      assertion = builtins.pathExists ../../assets/home_wallpaper.png;
      message = "Umbra desktop artwork is incomplete: assets/home_wallpaper.png is missing.";
    }
  ];
}
