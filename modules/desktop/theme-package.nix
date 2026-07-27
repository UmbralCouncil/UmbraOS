{ pkgs }:
pkgs.runCommand "umbra-plasma-look-and-feel-0.1.0" { } ''
  theme="$out/share/plasma/look-and-feel/dev.umbraos.desktop"
  mkdir -p "$theme/contents"
  cp ${./theme/metadata.json} "$theme/metadata.json"
  substitute ${./theme/defaults} "$theme/contents/defaults" \
    --replace-fail UMBRA_WALLPAPER ${../../assets/home_wallpaper.png}
''
