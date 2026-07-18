{ lib, ... }:
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
    ANSI_COLOR="1;34"
    DEFAULT_HOSTNAME=RTS
    CPE_NAME="cpe:/o:umbraos:umbraos:26.05/0.1"
  '';
}
