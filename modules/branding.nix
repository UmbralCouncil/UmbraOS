{ lib, settings, ... }:
let
  hexToDecimal = hex:
    let
      chars = { "0"=0; "1"=1; "2"=2; "3"=3; "4"=4; "5"=5; "6"=6; "7"=7;
                "8"=8; "9"=9; "a"=10; "b"=11; "c"=12; "d"=13; "e"=14; "f"=15; };
      str = lib.toLower hex;
      len = builtins.stringLength str;
    in
      lib.foldl (acc: i: acc * 16 + chars.${builtins.substring i 1 str}) 0 (lib.range 0 (len - 1));

  accent = settings.colorScheme.palette.base0D;
  r = toString (hexToDecimal (builtins.substring 0 2 accent));
  g = toString (hexToDecimal (builtins.substring 2 2 accent));
  b = toString (hexToDecimal (builtins.substring 4 2 accent));
in
{
  environment.etc."os-release".text = lib.mkForce ''
    NAME="UmbraOS"
    ID=umbra
    PRETTY_NAME="UmbraOS 26.05/0.1"
    VERSION="26.05/0.1"
    VERSION_ID="26.05/0.1"
    VERSION_CODENAME=quasar
    BUILD_ID="26.05/0.1"
    BUG_REPORT_URL="https://github.com/7apt/UmbraOS"
    VENDOR_NAME="UmbraOS"
    VENDOR_URL="https://github.com/7apt/UmbraOS"
    LOGO="nix-snowflake"
    HOME_URL="https://github.com/7apt/UmbraOS"
    DOCUMENTATION_URL="https://github.com/7apt/UmbraOS"
    SUPPORT_URL="https://github.com/7apt/UmbraOS"
    ANSI_COLOR="0;38;2;${r};${g};${b}"
    DEFAULT_HOSTNAME=RTS
    CPE_NAME="cpe:/o:umbraos:umbraos:26.05/0.1"
  '';
}
