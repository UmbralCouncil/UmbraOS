{ pkgs, source, flakeInputs }:
let
  runtimePath = pkgs.lib.makeBinPath [
    pkgs.bash pkgs.busybox pkgs.coreutils pkgs.curl pkgs.dosfstools pkgs.gawk
    pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.nix pkgs.nixos-install-tools
    pkgs.parted pkgs.socat pkgs.systemd pkgs.util-linux pkgs.whois pkgs.btrfs-progs
  ];
in
pkgs.runCommand "umbra-installer-0.1.0"
  {
    nativeBuildInputs = [
      pkgs.rustc
      pkgs.stdenv.cc
      pkgs.pkg-config
      pkgs.qt6.wrapQtAppsHook
    ];
    buildInputs = [
      pkgs.kdePackages.qtbase
      pkgs.kdePackages.qtwebengine
    ];
    dontWrapQtApps = true;
  }
  ''
  mkdir -p "$out/bin" "$out/libexec/umbra-installer/cgi-bin" \
    "$out/share/applications" "$out/share/icons/hicolor/256x256/apps"
  cp ${./www/index.html} "$out/libexec/umbra-installer/index.html"
  cp ${./www/style.css} "$out/libexec/umbra-installer/style.css"
  cp ${./www/app.js} "$out/libexec/umbra-installer/app.js"
  cp ${../assets/umbraos_logo.png} \
    "$out/libexec/umbra-installer/umbraos_logo.png"
  cp ${../assets/install.png} \
    "$out/share/icons/hicolor/256x256/apps/umbra-installer.png"
  substitute ${./backend.rs} backend.rs \
    --replace-fail @PATH@ '${runtimePath}' \
    --replace-fail @NIX@ '${pkgs.nix}/bin/nix' \
    --replace-fail @UMBRA_SOURCE@ '${source}' \
    --replace-fail @NIXPKGS_SOURCE@ '${flakeInputs.nixpkgs}' \
    --replace-fail @NIXPKGS_UNSTABLE_SOURCE@ '${flakeInputs.nixpkgs-unstable}' \
    --replace-fail @HOME_MANAGER_SOURCE@ '${flakeInputs.home-manager}' \
    --replace-fail @MICROVM_SOURCE@ '${flakeInputs.microvm}' \
    --replace-fail @SPECTRUM_SOURCE@ '${flakeInputs.microvm.inputs.spectrum}'
  rustc --edition=2021 -O backend.rs \
    -o "$out/libexec/umbra-installer/backend"
  "$CXX" -std=c++20 -O2 ${./webview.cpp} \
    -o "$out/libexec/umbra-installer/webview" \
    $(pkg-config --cflags --libs Qt6Widgets Qt6WebEngineWidgets)
  wrapQtApp "$out/libexec/umbra-installer/webview"
  substitute ${./bridge.sh} "$out/libexec/umbra-installer/cgi-bin/api" \
    --replace-fail @PATH@ '${runtimePath}' \
    --replace-fail @SOCKET@ /run/umbra-installer/backend.sock
  chmod +x "$out/libexec/umbra-installer/cgi-bin/api"
  substitute ${./launch.sh} "$out/bin/umbra-installer" \
    --replace-fail @BACKEND@ "$out/libexec/umbra-installer/backend" \
    --replace-fail @BUSYBOX@ '${pkgs.busybox}/bin/busybox' \
    --replace-fail @WEBROOT@ "$out/libexec/umbra-installer" \
    --replace-fail @WEBVIEW@ "$out/libexec/umbra-installer/webview" \
    --replace-fail @ICON@ \
      "$out/share/icons/hicolor/256x256/apps/umbra-installer.png"
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
