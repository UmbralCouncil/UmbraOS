{ pkgs }:
let
  runtimePath = pkgs.lib.makeBinPath [
    pkgs.bash pkgs.coreutils pkgs.curl pkgs.dosfstools pkgs.gawk pkgs.gnugrep pkgs.gnused
    pkgs.git pkgs.jq pkgs.niri pkgs.nix pkgs.nixos-install-tools pkgs.networkmanager pkgs.parted
    pkgs.systemd pkgs.util-linux pkgs.btrfs-progs
  ];
in
pkgs.rustPlatform.buildRustPackage {
  pname = "umbra-installer";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ pkgs.makeWrapper pkgs.pkg-config ];
  buildInputs = [
    pkgs.libglvnd
    pkgs.libxkbcommon
    pkgs.wayland
    pkgs.libx11
    pkgs.libxcursor
    pkgs.libxi
    pkgs.libxrandr
  ];

  postInstall = ''
    mkdir -p "$out/libexec/umbra-installer" "$out/share/applications" \
      "$out/share/icons/hicolor/256x256/apps"
    substitute ${./backend.rs} backend-generated.rs \
      --replace-fail @PATH@ '${runtimePath}' \
      --replace-fail @SYSTEM@ '${pkgs.stdenv.hostPlatform.system}' \
      --replace-fail @NIX@ '${pkgs.nix}/bin/nix' \
      --replace-fail @MKPASSWD@ '${pkgs.mkpasswd}/bin/mkpasswd' \
      --replace-fail @NIRI@ '${pkgs.niri}/bin/niri'
    rustc --edition=2021 -O backend-generated.rs -o "$out/libexec/umbra-installer/backend"
    wrapProgram "$out/bin/umbra-installer-ui" \
      --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib:${pkgs.lib.makeLibraryPath [
        pkgs.libglvnd
        pkgs.libxkbcommon
        pkgs.wayland
        pkgs.libx11
        pkgs.libxcursor
        pkgs.libxi
        pkgs.libxrandr
      ]} \
      --set-default __EGL_VENDOR_LIBRARY_DIRS /run/opengl-driver/share/glvnd/egl_vendor.d
    cp ${../assets/install.png} "$out/share/icons/hicolor/256x256/apps/umbra-installer.png"
    substitute ${./launch.sh} "$out/bin/umbra-installer" \
      --replace-fail @BACKEND@ "$out/libexec/umbra-installer/backend" \
      --replace-fail @GUI@ "$out/bin/umbra-installer-ui" \
      --replace-fail @FLOCK@ "${pkgs.util-linux}/bin/flock"
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
  '';
}
