{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "umbra-updater";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [ pkgs.makeWrapper pkgs.pkg-config ];
  buildInputs = [
    pkgs.libglvnd pkgs.libxkbcommon pkgs.wayland pkgs.libx11
    pkgs.libxcursor pkgs.libxi pkgs.libxrandr
  ];
  postPatch = ''
    substituteInPlace backend.rs \
      --replace-fail '@GIT@' '${pkgs.git}/bin/git' \
      --replace-fail '@NIXOS_REBUILD@' '${pkgs.nixos-rebuild}/bin/nixos-rebuild'
  '';
  postInstall = ''
    wrapProgram "$out/bin/umbra-update-ui" \
      --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib:${pkgs.lib.makeLibraryPath [
        pkgs.libglvnd pkgs.libxkbcommon pkgs.wayland pkgs.libx11
        pkgs.libxcursor pkgs.libxi pkgs.libxrandr
      ]} \
      --set-default __EGL_VENDOR_LIBRARY_DIRS /run/opengl-driver/share/glvnd/egl_vendor.d
    install -Dm644 ${../assets/install.png} \
      "$out/share/icons/hicolor/256x256/apps/umbra-update.png"
    mkdir -p "$out/share/applications"
    cat > "$out/share/applications/umbra-update.desktop" <<EOF
    [Desktop Entry]
    Type=Application
    Name=UmbraOS Update
    Comment=Check for and install UmbraOS system updates
    Exec=$out/bin/umbra-update-ui
    Icon=umbra-update
    Categories=System;Settings;
    StartupNotify=true
    EOF
  '';
}
