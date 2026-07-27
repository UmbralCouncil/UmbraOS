#!/usr/bin/env bash
set -euo pipefail

PATH="@PATH@"
WEBROOT="@WEBROOT@"
UMBRA_SOURCE="@UMBRA_SOURCE@"
PORT=43110

json_error() {
  printf 'Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n%s\n' "$1"
  exit 0
}

device_type() { lsblk -dnro TYPE -- "$1" 2>/dev/null || true; }
is_mounted() { findmnt -rnS "$1" >/dev/null 2>&1; }
tree_is_mounted() { lsblk -nrpo MOUNTPOINTS -- "$1" | grep -q '[^[:space:]]'; }

serve() {
  export UMBRA_INSTALLER_TOKEN="$1"
  exec busybox httpd -f -p "127.0.0.1:$PORT" -h "$WEBROOT"
}

cgi() {
  exec 2>>/tmp/umbra-installer.log
  printf '\n[%s] request %s\n' "$(date --iso-8601=seconds)" "${QUERY_STRING:-}" >&2
  trap 'cgi_failure "$LINENO" "$BASH_COMMAND" "$?"' ERR
  [ "${HTTP_X_UMBRA_TOKEN:-}" = "${UMBRA_INSTALLER_TOKEN:-}" ] ||
    json_error "invalid installer token"
  action="${QUERY_STRING#action=}"
  case "$action" in
    disks)
      printf 'Content-Type: application/json\r\n'
      printf 'Cache-Control: no-store\r\n\r\n'
      lsblk -J -b -o NAME,PATH,TYPE,SIZE,MODEL,FSTYPE,LABEL,PARTTYPE,MOUNTPOINTS
      ;;
    install)
      [ "${REQUEST_METHOD:-}" = POST ] || json_error "POST required"
      body="$(head -c "${CONTENT_LENGTH:-0}")"
      install_system "$body"
      ;;
    *) json_error "unknown action" ;;
  esac
}

cgi_failure() {
  line="$1"; command="$2"; status="$3"
  printf 'backend failure at line %s (exit %s): %s\n' \
    "$line" "$status" "$command" >&2
  printf 'Status: 500 Internal Server Error\r\n'
  printf 'Content-Type: text/plain\r\n'
  printf 'Cache-Control: no-store\r\n\r\n'
  printf 'Installer backend failed at line %s while running: %s\n' "$line" "$command"
  printf 'See /tmp/umbra-installer.log for details.\n'
  exit 0
}

install_system() {
  body="$1"
  printf 'starting validated install request\n' >&2
  mode="$(jq -r '.mode // empty' <<<"$body")"
  username="$(jq -r '.username // empty' <<<"$body")"
  hostname="$(jq -r '.hostname // empty' <<<"$body")"
  timezone="$(jq -r '.timezone // empty' <<<"$body")"
  password="$(jq -r '.password // empty' <<<"$body")"
  confirmation="$(jq -r '.confirmation // empty' <<<"$body")"

  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || json_error "invalid username"
  [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || json_error "invalid hostname"
  [[ "$timezone" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ ]] ||
    json_error "invalid time zone"
  [ -e "/etc/zoneinfo/$timezone" ] || json_error "unknown time zone"
  [ "${#password}" -ge 8 ] || json_error "password is too short"
  [ -d /sys/firmware/efi ] || json_error "Umbra Installer currently requires UEFI boot"

  if [ "$mode" = erase ]; then
    disk="$(jq -r '.disk // empty' <<<"$body")"
    [ "$(device_type "$disk")" = disk ] || json_error "target is not a disk"
    [ "$confirmation" = "ERASE $disk" ] || json_error "confirmation mismatch"
    ! tree_is_mounted "$disk" || json_error "target disk or one of its partitions is mounted"
    printf 'partitioning whole disk %s\n' "$disk" >&2
    wipefs --all --force "$disk"
    parted -s "$disk" mklabel gpt
    parted -s "$disk" mkpart ESP fat32 1MiB 1025MiB
    parted -s "$disk" set 1 esp on
    parted -s "$disk" mkpart UmbraOS btrfs 1025MiB 100%
    partprobe "$disk"
    udevadm settle
    if [[ "$disk" =~ (nvme|mmcblk) ]]; then
      esp="${disk}p1"; root="${disk}p2"
    else
      esp="${disk}1"; root="${disk}2"
    fi
    mkfs.fat -F 32 -n UMBRA_EFI "$esp"
  elif [ "$mode" = manual ]; then
    root="$(jq -r '.root // empty' <<<"$body")"
    esp="$(jq -r '.esp // empty' <<<"$body")"
    [ "$(device_type "$root")" = part ] || json_error "root target is not a partition"
    [ "$(device_type "$esp")" = part ] || json_error "EFI target is not a partition"
    [ "$root" != "$esp" ] || json_error "root and EFI partitions must differ"
    [ "$confirmation" = "FORMAT $root" ] || json_error "confirmation mismatch"
    ! is_mounted "$root" || json_error "root partition is mounted"
    [ "$(lsblk -dnro FSTYPE -- "$esp")" = vfat ] ||
      json_error "EFI System Partition must be FAT32"
    printf 'manual install: root=%s esp=%s\n' "$root" "$esp" >&2
  else
    json_error "invalid installation mode"
  fi

  cleanup() { umount -R /mnt 2>/dev/null || true; }
  trap cleanup EXIT
  mkfs.btrfs -f -L UMBRAOS "$root"
  printf 'mounting target filesystems\n' >&2
  mount "$root" /mnt
  mkdir -p /mnt/boot /mnt/etc
  mount "$esp" /mnt/boot

  cp -r "$UMBRA_SOURCE" /mnt/etc/umbra
  chmod -R u+w /mnt/etc/umbra
  nixos-generate-config --root /mnt
  printf 'generated target hardware configuration\n' >&2
  cp /mnt/etc/nixos/hardware-configuration.nix \
    /mnt/etc/umbra/profile/default/hardware.nix

  password_hash="$(mkpasswd -m yescrypt "$password")"
  cat > /mnt/etc/umbra/installer-settings.nix <<EOF
{
  timeZone = "$timezone";
  hostName = "$hostname";
  account = {
    name = "$username";
    hashedPassword = "$password_hash";
  };
}
EOF
  nixos-install --no-root-passwd --root /mnt \
    --flake "path:/mnt/etc/umbra#default"
  printf 'nixos-install completed\n' >&2
  sync
  cleanup
  trap - EXIT
  printf 'Content-Type: application/json\r\n'
  printf 'Cache-Control: no-store\r\n\r\n'
  jq -n --arg message "UmbraOS was installed successfully. You may reboot." \
    '{ok:true,message:$message}'
}

case "${1:-${GATEWAY_INTERFACE:+cgi}}" in
  serve) serve "$2" ;;
  cgi) cgi ;;
  *) echo "usage: $0 serve TOKEN|cgi" >&2; exit 2 ;;
esac
