{ pkgs }:
pkgs.runCommand "umbra-plasma-look-and-feel-0.1.0" { } ''
  theme="$out/share/plasma/look-and-feel/dev.umbraos.desktop"
  mkdir -p "$theme/contents/plasmoidsetupscripts"
  cp ${./theme/metadata.json} "$theme/metadata.json"
  substitute ${./theme/defaults} "$theme/contents/defaults" \
    --replace-fail UMBRA_WALLPAPER UmbraOS
  for launcher in \
    org.kde.plasma.kickoff \
    org.kde.plasma.kicker \
    org.kde.plasma.kickerdash
  do
    cp ${./theme/application-launcher.js} \
      "$theme/contents/plasmoidsetupscripts/$launcher.js"
  done

  # Ship desktop artwork through the system profile as well as Home Manager.
  # Plasma can then resolve it even if a live-session user link is recreated or
  # its icon cache initializes before the per-user tmpfiles rules run.
  mkdir -p \
    "$out/share/wallpapers/UmbraOS/contents/images" \
    "$out/share/icons/hicolor/scalable/apps" \
    "$out/share/icons/hicolor/scalable/places"
  cp ${../../assets/home_wallpaper.png} \
    "$out/share/wallpapers/UmbraOS/contents/images/2560x1600.png"
  cp ${./theme/wallpaper-metadata.json} \
    "$out/share/wallpapers/UmbraOS/metadata.json"
  cp ${../../assets/darkmode_application_button.svg} \
    "$out/share/icons/hicolor/scalable/apps/umbra-application-dark.svg"
  cp ${../../assets/lightmode_application_button.svg} \
    "$out/share/icons/hicolor/scalable/apps/umbra-application-light.svg"
  cp ${../../assets/darkmode_application_button.svg} \
    "$out/share/icons/hicolor/scalable/places/start-here.svg"
  cp ${../../assets/darkmode_application_button.svg} \
    "$out/share/icons/hicolor/scalable/places/start-here-kde-symbolic.svg"
''
