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
  releaseArchive ? null,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "umbra-studio-bin";
  version = "0.2.1";

  src = if releaseArchive != null then releaseArchive else fetchurl ({
    url = "https://github.com/UmbralCouncil/UmbraOS/releases/download/studio-v${finalAttrs.version}/umbra-studio-${stdenv.hostPlatform.system}.tar.zst";
  } // {
      x86_64-linux = {
        hash = "sha256-LK8x397dzw0qZc+ChijEEuQmx86+K+aB4Bw1z30mEDY=";
      };
      # Replace after producing the first native ARM64 release bundle. A local
      # source-free archive can be supplied with umbra.studio.releaseArchive.
      aarch64-linux = { hash = "sha256-kK/DiJkd1mZ0TkylNKjyMAjRAFVuurQuN5B243hmR1I="; };
    }.${stdenv.hostPlatform.system});

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
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
