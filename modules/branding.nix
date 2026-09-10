{ lib, ... }:
{
  environment.etc."os-release".text = lib.mkForce ''
    NAME="UmbraOS"
    ID=umbra
    ID_LIKE=nixos
    PRETTY_NAME="UmbraOS 26.05 (Quasar)"
    VERSION="26.05 (Quasar)"
    VERSION_ID="26.05"
    VERSION_CODENAME=quasar
    BUILD_ID="26.05"
    BUG_REPORT_URL="https://github.com/UmbralCouncil/UmbraOS/issues"
    VENDOR_NAME="Umbral Council"
    VENDOR_URL="https://taptsec.dev"
    LOGO="umbraos"
    HOME_URL="https://taptsec.dev"
    DOCUMENTATION_URL="https://github.com/UmbralCouncil/UmbraOS#readme"
    SUPPORT_URL="https://github.com/UmbralCouncil/UmbraOS/issues"
    ANSI_COLOR="1;35"
    DEFAULT_HOSTNAME=umbra
    CPE_NAME="cpe:2.3:o:umbral_council:umbraos:26.05:*:*:*:*:*:*:*"
  '';
}
