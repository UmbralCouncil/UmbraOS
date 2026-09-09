{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  zstd,
  coreRunner,
  mistralCpuRunner,
  llamaVulkanRunner,
  openssl,
  dbus,
  fontconfig,
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
  version = "0.1.9";

  src = fetchurl {
    url = "https://github.com/UmbralCouncil/UmbraOS/releases/download/studio-v${finalAttrs.version}/umbra-studio-x86_64-linux.tar.zst";
    hash = "sha256-zx0k3ii01rKMLOEg9bz3bFnmBk2Q+PV6ljjM4Dv3lDc=";
  };

  sourceRoot = ".";
  nativeBuildInputs = [ autoPatchelfHook makeWrapper zstd ];
  buildInputs = [
    stdenv.cc.cc.lib
    openssl
    dbus
    fontconfig
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
      --set UMBRA_MISTRAL_CPU_RUNNER "${mistralCpuRunner}/bin/mistralrs" \
      --set UMBRA_LLAMA_VULKAN_RUNNER "${llamaVulkanRunner}/bin/llama-server" \
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
