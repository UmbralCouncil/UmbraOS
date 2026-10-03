{ lib, stdenv, fetchurl, autoPatchelfHook, makeWrapper, zstd,
  alsa-lib, atk, at-spi2-atk, cairo, cups, dbus, expat, fontconfig, freetype,
  glib, gtk3, libdrm, libgbm, libGL, libpulseaudio, libxkbcommon, libxslt,
  mesa, nspr, nss, pango, flac, systemd, wayland, libx11, libxcb,
  libxcomposite, libxdamage, libxext,
  libxfixes, libxrandr, releaseArchive ? null }:

let
  release = {
    x86_64-linux = { version = "0.0.2"; hash = "sha256-s/LMVlpZKgvz9TJG0CB9PVODvHLYmTlaNkXjba2FNXA="; };
    aarch64-linux = { version = "0.0.2"; hash = "sha256-hISZwRW5WSKflZ9+qOeXuuOf81UFYNFC/NNffpPibuw="; };
  }.${stdenv.hostPlatform.system};
in stdenv.mkDerivation (finalAttrs: {
  pname = "umbra-note-bin";
  inherit (release) version;
  src = if releaseArchive != null then releaseArchive else fetchurl {
    url = "https://github.com/UmbralCouncil/UmbraNote/releases/download/v${finalAttrs.version}/umbra-note-${stdenv.hostPlatform.system}.tar.zst";
    inherit (release) hash;
  };
  sourceRoot = ".";
  nativeBuildInputs = [ autoPatchelfHook makeWrapper zstd ];
  buildInputs = [
    stdenv.cc.cc.lib alsa-lib atk at-spi2-atk cairo cups dbus expat fontconfig
    freetype glib gtk3 libdrm libgbm libGL libpulseaudio libxkbcommon libxslt
    mesa nspr nss pango flac systemd wayland libx11 libxcb libxcomposite
    libxdamage libxext libxfixes libxrandr
  ];
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -R bin lib share $out/
    # Published bundles must use /bin/sh, but normalize older bundles too so
    # an interpreter from the producer's Nix store can never leak through.
    sed -i '1c #!/bin/sh' $out/bin/umbra-note
    wrapProgram $out/lib/umbra-note/electron/electron \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath finalAttrs.buildInputs}"
    runHook postInstall
  '';
  meta = {
    description = "Local-first Markdown notebook with live preview";
    license = lib.licenses.gpl3Plus;
    mainProgram = "umbra-note";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
