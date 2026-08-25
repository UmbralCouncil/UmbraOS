{ pkgs, source }:
pkgs.writeShellApplication {
  name = "umbra-migrate";

  runtimeInputs = with pkgs; [
    coreutils
    gawk
    getent
    gnugrep
    gnused
    hostname
    jq
    nix
    nixos-install-tools
    nixos-rebuild
    shadow
    sudo
    systemd
    util-linux
  ];

  text = ''
    set -euo pipefail

    mode=build
    migration_user=
    allow_graphical=
    original_args=("$@")

    usage() {
      cat <<'EOF'
    Usage: umbra-migrate [--build|--test|--switch] [--user USER]

      --build    Build and dry-activate only (default; does not change the system)
      --test     Activate until reboot; must be run from a Linux virtual console
      --switch   Activate permanently; must be run from a Linux virtual console
      --user     Preserve this existing normal user's login and home

    Recommended:
      1. Press Ctrl+Alt+F3 and log in.
      2. cd to the UmbraOS checkout.
      3. nix run .#migrate -- --build
      4. nix run .#migrate -- --switch

    Rollback after switching:
      sudo nixos-rebuild switch --rollback
    EOF
    }

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --build) mode='build' ;;
        --test) mode='test' ;;
        --switch) mode='switch' ;;
        --user)
          shift
          [ "$#" -gt 0 ] || {
            echo "umbra-migrate: --user requires a username" >&2
            exit 2
          }
          migration_user="$1"
          ;;
        --internal-user)
          shift
          [ "$#" -gt 0 ] || exit 2
          migration_user="$1"
          ;;
        --allow-graphical) allow_graphical=1 ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          echo "umbra-migrate: unknown argument '$1'" >&2
          usage >&2
          exit 2
          ;;
      esac
      shift
    done

    if [ "$EUID" -ne 0 ]; then
      exec sudo "$0" --internal-user "$(id -un)" "''${original_args[@]}"
    fi

    if [ -z "$migration_user" ] && [ -n "''${SUDO_USER:-}" ]; then
      migration_user="$SUDO_USER"
    fi
    if [ -z "$migration_user" ]; then
      echo "umbra-migrate: cannot infer the account to preserve; pass --user USER" >&2
      exit 2
    fi
    if ! [[ "$migration_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      echo "umbra-migrate: unsafe or unsupported username '$migration_user'" >&2
      exit 2
    fi
    if ! user_record="$(getent passwd "$migration_user")"; then
      echo "umbra-migrate: user '$migration_user' does not exist" >&2
      exit 2
    fi

    user_uid="$(printf '%s\n' "$user_record" | cut -d: -f3)"
    user_home="$(printf '%s\n' "$user_record" | cut -d: -f6)"
    primary_group="$(id -gn "$migration_user")"
    if [ "$user_uid" -lt 1000 ]; then
      echo "umbra-migrate: refusing to migrate non-normal UID $user_uid" >&2
      exit 2
    fi
    if [ ! -d "$user_home" ]; then
      echo "umbra-migrate: home directory '$user_home' does not exist" >&2
      exit 2
    fi
    previous_system_profile="$(readlink -f /run/current-system/sw)"
    if ! [[ "$previous_system_profile" =~ ^/nix/store/[^/]+$ ]] \
      || [ ! -d "$previous_system_profile" ]; then
      echo "umbra-migrate: could not resolve the current system software profile" >&2
      exit 2
    fi

    if [ "$mode" != build ] && [ -z "$allow_graphical" ]; then
      active_tty="$(tty 2>/dev/null || true)"
      if ! [[ "$active_tty" =~ ^/dev/tty[0-9]+$ ]]; then
        cat >&2 <<'EOF'
    umbra-migrate: refusing to replace the display manager from a graphical
    terminal. Press Ctrl+Alt+F3, log in, and run the command there.
    Use --allow-graphical only if you accept that the terminal may disappear.
    EOF
        exit 2
      fi
    fi

    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    migration_root="/var/lib/umbra/migrations"
    target="$migration_root/$stamp"
    install -d -m 0755 "$migration_root"
    install -d -m 0755 "$target"
    cp -a ${source}/. "$target/"

    echo "Generating host hardware configuration..."
    nixos-generate-config --show-hardware-config > "$target/migration-hardware.nix"

    nix_quote() {
      printf '%s' "$1" | jq -Rs .
    }

    host_name="$(hostnamectl hostname 2>/dev/null || hostname)"
    host_name="''${host_name%%.*}"
    if ! [[ "$host_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]; then
      echo "umbra-migrate: current hostname is invalid for NixOS; using 'umbra'" >&2
      host_name=umbra
    fi
    time_zone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
    [ -n "$time_zone" ] || time_zone=UTC

    extra_groups=
    group_declarations=
    while IFS= read -r group_name; do
      [ -n "$group_name" ] || continue
      group_record="$(getent group "$group_name")"
      group_gid="$(printf '%s\n' "$group_record" | cut -d: -f3)"
      quoted_group="$(nix_quote "$group_name")"
      group_declarations="$group_declarations
        $quoted_group = { gid = $group_gid; };"
      if [ "$group_name" != "$primary_group" ]; then
        extra_groups="$extra_groups $quoted_group"
      fi
    done < <(id -nG "$migration_user" | tr ' ' '\n' | sort -u)

    cat > "$target/migration-settings.nix" <<EOF
    {
      hostName = $(nix_quote "$host_name");
      timeZone = $(nix_quote "$time_zone");
      account = {
        name = $(nix_quote "$migration_user");
        uid = $user_uid;
        home = $(nix_quote "$user_home");
        group = $(nix_quote "$primary_group");
        extraGroups = [ $extra_groups ];
        preservePassword = true;
      };
    }
    EOF

    cat > "$target/migration-host.nix" <<EOF
    { lib, pkgs, ... }:
    let
      previousSystemSoftware = pkgs.symlinkJoin {
        name = "umbra-preserved-system-software";
        paths = [ (builtins.storePath $(nix_quote "$previous_system_profile")) ];
      };
    in
    {
      # Existing shadow entries remain authoritative during migration.
      users.mutableUsers = true;
      users.groups = {$group_declarations
      };

      # Retain every program exposed by the pre-migration system profile.
      # UmbraOS packages have normal priority; this compatibility profile has
      # low priority, so Umbra wins collisions without dropping other apps.
      environment.systemPackages = [
        (lib.lowPrio previousSystemSoftware)
      ];
    }
    EOF

    chmod 0644 \
      "$target/migration-hardware.nix" \
      "$target/migration-settings.nix" \
      "$target/migration-host.nix"

    flake_ref="path:$target#umbra-migration"
    cd "$target"

    echo "Building the host-specific UmbraOS generation..."
    # The generated host module deliberately references the already-installed
    # system profile with builtins.storePath. That host-local reference is
    # unavailable to pure flake evaluation, so migration evaluations must be
    # explicitly impure.
    nixos-rebuild build --impure --flake "$flake_ref"
    sddm_config="result/etc/sddm.conf.d/00-nixos.conf"
    wayland_session_dir="$(
      awk '
        $0 == "[Wayland]" { in_wayland = 1; next }
        /^\[/ { in_wayland = 0 }
        in_wayland && /^SessionDir=/ {
          sub(/^SessionDir=/, "")
          print
          exit
        }
      ' "$sddm_config" 2>/dev/null || true
    )"
    if ! grep -qx 'DefaultSession=hyprland.desktop' "$sddm_config" \
      || [ -z "$wayland_session_dir" ] \
      || [ ! -e "$wayland_session_dir/hyprland.desktop" ]; then
      echo "umbra-migrate: built system does not contain the Hyprland login session" >&2
      exit 1
    fi

    echo "Checking activation changes without applying them..."
    nixos-rebuild dry-activate --impure --flake "$flake_ref"

    if [ "$mode" = build ]; then
      cat <<EOF

    Build and dry activation succeeded. No system state was changed.
    Snapshot: $target

    From Ctrl+Alt+F3, activate it with:
      sudo nixos-rebuild switch --impure --flake '$flake_ref'

    Roll back with:
      sudo nixos-rebuild switch --rollback
    EOF
      exit 0
    fi

    password_before="$(getent shadow "$migration_user" | cut -d: -f2)"
    echo "Activating UmbraOS in '$mode' mode..."
    nixos-rebuild "$mode" --impure --flake "$flake_ref"
    password_after="$(getent shadow "$migration_user" | cut -d: -f2)"

    if [ "$password_before" != "$password_after" ]; then
      echo "umbra-migrate: password state changed; rolling back immediately" >&2
      nixos-rebuild switch --rollback || true
      exit 1
    fi

    if [ "$mode" = switch ]; then
      if [ -e /etc/nixos/umbra ] && [ ! -L /etc/nixos/umbra ]; then
        echo "umbra-migrate: /etc/nixos/umbra already exists; snapshot remains at $target" >&2
      else
        ln -sfn "$target" /etc/nixos/umbra
      fi
    fi

    cat <<EOF

    UmbraOS '$mode' activation completed.
    Account preserved: $migration_user
    Password shadow entry: unchanged
    Previous software profile: retained at low priority
    Snapshot: $target

    Roll back with:
      sudo nixos-rebuild switch --rollback
    EOF
  '';
}
