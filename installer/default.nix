{ pkgs, source, flakeInputs }:
let
  runtimePath = pkgs.lib.makeBinPath [
    pkgs.bash pkgs.coreutils pkgs.dosfstools pkgs.gawk pkgs.gnugrep pkgs.gnused
    pkgs.jq pkgs.nix pkgs.nixos-install-tools pkgs.networkmanager pkgs.parted
    pkgs.systemd pkgs.util-linux pkgs.whois pkgs.btrfs-progs
  ];
in
pkgs.rustPlatform.buildRustPackage {
  pname = "umbra-installer";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [
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
      --replace-fail @NIX@ '${pkgs.nix}/bin/nix' \
      --replace-fail @UMBRA_SOURCE@ '${source}' \
      --replace-fail @NIXPKGS_SOURCE@ '${flakeInputs.nixpkgs}' \
      --replace-fail @NIXPKGS_UNSTABLE_SOURCE@ '${flakeInputs.nixpkgs-unstable}' \
      --replace-fail @HOME_MANAGER_SOURCE@ '${flakeInputs.home-manager}' \
      --replace-fail @MICROVM_SOURCE@ '${flakeInputs.microvm}' \
      --replace-fail @SPECTRUM_SOURCE@ '${flakeInputs.microvm.inputs.spectrum}'
    rustc --edition=2021 -O backend-generated.rs -o "$out/libexec/umbra-installer/backend"
    cp ${../assets/install.png} "$out/share/icons/hicolor/256x256/apps/umbra-installer.png"
    substitute ${./launch.sh} "$out/bin/umbra-installer" \
      --replace-fail @BACKEND@ "$out/libexec/umbra-installer/backend" \
      --replace-fail @GUI@ "$out/bin/umbra-installer-ui"
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
