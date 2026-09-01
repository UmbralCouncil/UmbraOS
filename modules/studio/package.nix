{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  zstd,
  coreRunner,
  openssl,
  libGL,
  libxkbcommon,
  wayland,
  libx11,
  libxi,
  libxcursor,
  libxrandr,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "umbra-studio-bin";
  version = "0.1.1";

  src = fetchurl {
    url = "https://github.com/UmbralCouncil/UmbraOS/releases/download/studio-v${finalAttrs.version}/umbra-studio-x86_64-linux.tar.zst";
    # Filled after the v0.1.1 source-free bundle is published.
    hash = lib.fakeHash;
  };

  sourceRoot = ".";
  nativeBuildInputs = [ autoPatchelfHook makeWrapper zstd ];
  buildInputs = [
    stdenv.cc.cc.lib
    openssl
    libGL
    libxkbcommon
    wayland
    libx11
    libxi
    libxcursor
    libxrandr
  ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -R bin share $out/
    wrapProgram $out/bin/umbra-studio \
      --set UMBRA_MICROVM_RUNNER "${coreRunner}/bin/microvm-run" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath finalAttrs.buildInputs}"
    runHook postInstall
  '';

  meta = {
    description = "Native Umbra security-training application";
    license = lib.licenses.unfree;
    mainProgram = "umbra-studio";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
