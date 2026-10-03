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

let
  release = {
    x86_64-linux = {
      version = "0.2.2";
      hash = "sha256-bh/UFGzhv3jvx1kqwWl2tkru1AaRDQwIWil9RsA1fts=";
    };
    aarch64-linux = {
      version = "0.2.2";
      hash = "sha256-jWBtlpXjv8HHwYrHBjAQM0JtCh0/dIn+T8rvVgl29Uk=";
    };
  }.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation (finalAttrs: {
  pname = "umbra-studio-bin";
  inherit (release) version;

  src = if releaseArchive != null then releaseArchive else fetchurl {
    url = "https://github.com/UmbralCouncil/UmbraOS/releases/download/studio-v${finalAttrs.version}/umbra-studio-${stdenv.hostPlatform.system}.tar.zst";
    inherit (release) hash;
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
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
