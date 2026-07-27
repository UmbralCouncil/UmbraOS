{ pkgs, source }:
let
  runtimePath = pkgs.lib.makeBinPath [
    pkgs.bash pkgs.busybox pkgs.coreutils pkgs.curl pkgs.dosfstools pkgs.gawk
    pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.nix pkgs.nixos-install-tools
    pkgs.parted pkgs.systemd pkgs.util-linux pkgs.whois pkgs.btrfs-progs
  ];
in
pkgs.runCommand "umbra-installer-0.1.0" { } ''
  mkdir -p "$out/bin" "$out/libexec/umbra-installer/cgi-bin" \
    "$out/share/applications" "$out/share/icons/hicolor/256x256/apps"
  cp ${./www/index.html} "$out/libexec/umbra-installer/index.html"
  cp ${./www/style.css} "$out/libexec/umbra-installer/style.css"
  cp ${./www/app.js} "$out/libexec/umbra-installer/app.js"
  cp ${../assets/logo.png} "$out/libexec/umbra-installer/logo.png"
  cp ${../assets/install.png} \
    "$out/share/icons/hicolor/256x256/apps/umbra-installer.png"
  substitute ${./backend.sh} "$out/libexec/umbra-installer/cgi-bin/api" \
    --replace-fail @PATH@ '${runtimePath}' \
    --replace-fail @WEBROOT@ "$out/libexec/umbra-installer" \
    --replace-fail @UMBRA_SOURCE@ '${source}'
  chmod +x "$out/libexec/umbra-installer/cgi-bin/api"
  substitute ${./launch.sh} "$out/bin/umbra-installer" \
    --replace-fail @BACKEND@ "$out/libexec/umbra-installer/cgi-bin/api" \
    --replace-fail @FIREFOX@ '${pkgs.firefox}/bin/firefox'
  chmod +x "$out/bin/umbra-installer"
  cat > "$out/share/applications/umbra-installer.desktop" <<EOF
  [Desktop Entry]
  Type=Application
  Name=Install UmbraOS
  Comment=Install UmbraOS to this computer
  Exec=$out/bin/umbra-installer
  Icon=umbra-installer
  Categories=System;
  StartupNotify=true
  EOF
''
