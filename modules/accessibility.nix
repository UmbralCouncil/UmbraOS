{ lib, pkgs, ... }:
let
  fenrir = pkgs.python3Packages.buildPythonApplication rec {
    pname = "fenrir-screenreader";
    version = "1.9.6.post1";
    pyproject = false;

    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/b0/cf/4798d41f159a4dced0aa48391ca3e5fb70ecbb42ac2fad7be7141230b29b/fenrir-screenreader-${version}.tar.gz";
      hash = "sha256-c/+QXuYUL6hJYGI/L7krwZ8xxDf6ffhn4ULCBz7GwMM=";
    };

    dependencies = with pkgs.python3Packages; [
      daemonize
      dbus-python
      evdev
      pexpect
      pyte
      pyttsx3
      pyudev
      setuptools
    ];

    # Upstream's setup.py uses FHS-absolute data paths. Keep all packaged data
    # inside the immutable output; NixOS exposes the mutable settings file below.
    postPatch = ''
      substituteInPlace setup.py \
        --replace-fail "'/etc/fenrirscreenreader/" "'etc/fenrirscreenreader/" \
        --replace-fail "'/usr/share/" "'share/"
    '';

    postInstall = ''
      cp $out/etc/fenrirscreenreader/settings/settings.conf.example \
        $out/etc/fenrirscreenreader/settings/settings.conf
      substituteInPlace $out/etc/fenrirscreenreader/settings/settings.conf \
        --replace-fail "/usr/share/fenrirscreenreader" "$out/share/fenrirscreenreader" \
        --replace-fail "/usr/share/sounds/fenrirscreenreader" "$out/share/sounds/fenrirscreenreader"

      wrapProgram $out/bin/fenrir \
        --prefix PATH : ${lib.makeBinPath [ pkgs.espeak-ng pkgs.sox ]}
      wrapProgram $out/bin/fenrir-daemon \
        --prefix PATH : ${lib.makeBinPath [ pkgs.espeak-ng pkgs.sox ]}
    '';

    doCheck = false;

    meta = {
      description = "TTY screen reader for Linux";
      homepage = "https://git.stormux.org/storm/fenrir";
      license = lib.licenses.lgpl3Plus;
      platforms = lib.platforms.linux;
      mainProgram = "fenrir";
    };
  };
in
{
  # Plasma consumes Orca through AT-SPI and speech-dispatcher. The upstream
  # Plasma module also defaults this on, but make the accessibility contract
  # explicit here so it cannot disappear if that default changes.
  services.orca.enable = true;

  # eSpeakup is the default console reader and needs the kernel Speakup bridge.
  boot.kernelModules = [ "speakup_soft" ];
  environment.systemPackages = [ pkgs.espeakup fenrir ];

  systemd.services.espeakup = {
    description = "eSpeakup console screen reader";
    wantedBy = [ "multi-user.target" ];
    after = [ "sound.target" ];
    conflicts = [ "fenrir.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.espeakup}/bin/espeakup";
      Restart = "on-failure";
    };
  };

  # Fenrir is installed and service-ready, but is not started alongside
  # eSpeakup because both readers would speak and intercept the same console.
  # Select it with: sudo systemctl disable --now espeakup; sudo systemctl start fenrir
  systemd.services.fenrir = {
    description = "Fenrir console screen reader";
    after = [ "sound.target" "systemd-udev-settle.service" ];
    conflicts = [ "espeakup.service" ];
    serviceConfig = {
      Type = "forking";
      ExecStart = "${fenrir}/bin/fenrir-daemon";
      Restart = "on-failure";
    };
  };

  environment.etc."fenrirscreenreader".source =
    "${fenrir}/etc/fenrirscreenreader";

  systemd.tmpfiles.rules = [
    "d /var/log/fenrirscreenreader 0755 root root - -"
  ];
}
