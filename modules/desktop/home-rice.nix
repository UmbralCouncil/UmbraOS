{ config, lib, pkgs, ... }:
let
  wallpaper = ../../assets/home_wallpaper.png;
  umbraPlasmaTheme = import ./theme-package.nix { inherit pkgs; };
in
{
  # User-visible copies make the supplied artwork discoverable in Plasma's
  # wallpaper and icon choosers instead of hiding it behind a store path.
  xdg.dataFile = {
    "wallpapers/UmbraOS/contents/images/2560x1600.png".source = wallpaper;
    "icons/hicolor/256x256/apps/umbraos.png".source = ../../assets/logo.png;
    "icons/hicolor/scalable/apps/umbra-application-dark.svg".source =
      ../../assets/darkmode_application_button.svg;
    "icons/hicolor/scalable/apps/umbra-application-light.svg".source =
      ../../assets/lightmode_application_button.svg;
    # Plasma's default launcher resolves one of these standard icon names.
    # Umbra Dark is the default scheme, so use the supplied light-on-dark mark.
    "icons/hicolor/scalable/places/start-here.svg".source =
      ../../assets/darkmode_application_button.svg;
    "icons/hicolor/scalable/places/start-here-kde-symbolic.svg".source =
      ../../assets/darkmode_application_button.svg;

    "color-schemes/UmbraDark.colors".text = ''
      [General]
      Name=Umbra Dark
      ColorScheme=UmbraDark
      shadeSortColumn=true

      [Colors:Window]
      BackgroundNormal=5,13,45
      ForegroundNormal=238,240,255
      DecorationFocus=181,177,255
      DecorationHover=199,187,255

      [Colors:View]
      BackgroundNormal=8,20,57
      BackgroundAlternate=17,30,70
      ForegroundNormal=238,240,255
      ForegroundInactive=163,168,190
      ForegroundLink=181,177,255
      ForegroundVisited=215,184,246
      DecorationFocus=181,177,255
      DecorationHover=199,187,255

      [Colors:Button]
      BackgroundNormal=22,36,78
      BackgroundAlternate=30,45,91
      ForegroundNormal=238,240,255
      ForegroundInactive=163,168,190
      DecorationFocus=181,177,255
      DecorationHover=199,187,255

      [Colors:Selection]
      BackgroundNormal=108,105,190
      BackgroundAlternate=124,119,207
      ForegroundNormal=255,255,255
      ForegroundInactive=225,225,239
      DecorationFocus=198,193,255
      DecorationHover=217,212,255

      [Colors:Tooltip]
      BackgroundNormal=231,224,192
      ForegroundNormal=10,18,47

      [Colors:Complementary]
      BackgroundNormal=3,11,38
      ForegroundNormal=238,240,255
      DecorationFocus=181,177,255
      DecorationHover=199,187,255

      [WM]
      activeBackground=8,20,57
      activeForeground=238,240,255
      inactiveBackground=20,29,63
      inactiveForeground=163,168,190
      activeBlend=108,105,190
      inactiveBlend=20,29,63

      [KDE]
      contrast=4
    '';

    "color-schemes/UmbraLight.colors".text = ''
      [General]
      Name=Umbra Light
      ColorScheme=UmbraLight
      shadeSortColumn=true

      [Colors:Window]
      BackgroundNormal=248,246,239
      ForegroundNormal=5,25,48
      DecorationFocus=108,105,190
      DecorationHover=124,119,207

      [Colors:View]
      BackgroundNormal=255,252,240
      BackgroundAlternate=236,242,250
      ForegroundNormal=5,25,48
      ForegroundInactive=93,101,119
      ForegroundLink=78,74,166
      ForegroundVisited=129,91,176
      DecorationFocus=108,105,190
      DecorationHover=124,119,207

      [Colors:Button]
      BackgroundNormal=238,236,228
      BackgroundAlternate=226,231,244
      ForegroundNormal=5,25,48
      ForegroundInactive=93,101,119
      DecorationFocus=108,105,190
      DecorationHover=124,119,207

      [Colors:Selection]
      BackgroundNormal=108,105,190
      BackgroundAlternate=124,119,207
      ForegroundNormal=255,255,255
      ForegroundInactive=238,238,248
      DecorationFocus=78,74,166
      DecorationHover=92,88,180

      [Colors:Tooltip]
      BackgroundNormal=255,243,202
      ForegroundNormal=5,25,48

      [Colors:Complementary]
      BackgroundNormal=5,25,48
      ForegroundNormal=248,246,239
      DecorationFocus=181,177,255
      DecorationHover=199,187,255

      [WM]
      activeBackground=238,236,228
      activeForeground=5,25,48
      inactiveBackground=226,231,244
      inactiveForeground=93,101,119
      activeBlend=108,105,190
      inactiveBlend=226,231,244

      [KDE]
      contrast=4
    '';
  };

  # KDE reads these as the user's normal defaults; they remain editable in
  # System Settings after deployment.
  xdg.configFile."kdeglobals".text = ''
    [General]
    ColorScheme=UmbraDark
    Name=Umbra Dark

    [Icons]
    Theme=breeze-dark

    [KDE]
    LookAndFeelPackage=dev.umbraos.desktop
    SingleClick=false
  '';

  # Plasma's wallpaper command needs a running desktop session. Apply it once
  # on login, then leave subsequent user customization alone.
  home.file.".local/bin/umbra-apply-rice" = {
    executable = true;
    text = ''
      #!${pkgs.runtimeShell}
      set -eu
      marker="$HOME/.config/umbra/rice-v1"
      if [ -e "$marker" ]; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/mkdir -p "$HOME/.config/umbra"
      ${pkgs.kdePackages.plasma-workspace}/bin/plasma-apply-lookandfeel \
        --apply dev.umbraos.desktop
      ${pkgs.kdePackages.plasma-workspace}/bin/plasma-apply-wallpaperimage \
        ${lib.escapeShellArg (toString wallpaper)}
      ${pkgs.coreutils}/bin/touch "$marker"
    '';
  };

  home.packages = [ umbraPlasmaTheme ];

  xdg.configFile."autostart/umbra-rice.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Apply UmbraOS desktop defaults
    Exec=${config.home.homeDirectory}/.local/bin/umbra-apply-rice
    OnlyShowIn=KDE;
    NoDisplay=true
    X-KDE-autostart-after=panel
  '';
}
