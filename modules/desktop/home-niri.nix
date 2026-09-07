{ lib, pkgs, ... }:
let
  wallpaper = ../../assets/home_wallpaper.png;
  applicationButton = ../../assets/darkmode_application_button.svg;
in
{
  home.packages = with pkgs; [ adwaita-icon-theme papirus-icon-theme ];

  home.pointerCursor = {
    gtk.enable = true;
    x11.enable = true;
    package = pkgs.adwaita-icon-theme;
    name = "Adwaita";
    size = 24;
  };

  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    setSessionVariables = true;
  };

  xdg.configFile = {
    "niri/config.kdl".text = ''
      // UmbraOS Niri session.
      include "live.kdl"

      spawn-at-startup "${pkgs.swaybg}/bin/swaybg" "-i" "${wallpaper}" "-m" "fill"
      spawn-at-startup "${pkgs.waybar}/bin/waybar"
      spawn-at-startup "${pkgs.mako}/bin/mako"
      spawn-at-startup "${pkgs.networkmanagerapplet}/bin/nm-applet" "--indicator"
      spawn-at-startup "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"

      environment {
          GTK_THEME "Adwaita:dark"
          XCURSOR_THEME "Adwaita"
          XCURSOR_SIZE "24"
      }

      cursor {
          xcursor-theme "Adwaita"
          xcursor-size 24
      }

      input {
          keyboard {
              xkb { layout "us"; }
          }
          touchpad {
              tap
          }
          mouse {
              accel-speed 0.0
          }
          focus-follows-mouse max-scroll-amount="0%"
          workspace-auto-back-and-forth
      }

      layout {
          gaps 8
          center-focused-column "on-overflow"
          always-center-single-column
          default-column-width { proportion 0.5; }
          preset-column-widths {
              proportion 0.33333
              proportion 0.5
              proportion 0.66667
          }
          focus-ring { off; }
          border {
              on
              width 2
              active-gradient from="#9d7cff" to="#50b7f5" angle=45 relative-to="workspace-view"
              inactive-color "#273253aa"
              urgent-color "#ff6b8a"
          }
          shadow {
              on
              softness 24
              spread 3
              offset x=0 y=5
              color "#00000088"
          }
          struts { bottom 4; }
      }

      prefer-no-csd
      screenshot-path "~/Pictures/Screenshot-%Y-%m-%d-%H%M%S.png"

      window-rule {
          geometry-corner-radius 8
          clip-to-geometry true
      }

      animations { slowdown 0.9; }

      binds {
          Mod+Shift+Slash { show-hotkey-overlay; }
          Mod+Q hotkey-overlay-title="Open Kitty" { spawn "${pkgs.kitty}/bin/kitty"; }
          Mod+Shift+Q hotkey-overlay-title="Open accessible terminal" { spawn "${pkgs.gnome-terminal}/bin/gnome-terminal"; }
          Mod+E hotkey-overlay-title="Open Files" { spawn "${pkgs.pcmanfm}/bin/pcmanfm"; }
          Mod+R hotkey-overlay-title="Search Applications" { spawn "${pkgs.wofi}/bin/wofi" "--show" "drun"; }
          Mod+L allow-when-locked=true hotkey-overlay-title="Lock Session" { spawn "${pkgs.swaylock-effects}/bin/swaylock"; }
          Mod+Alt+S hotkey-overlay-title="Toggle Orca screen reader" { spawn-sh "if ${pkgs.procps}/bin/pgrep -x orca >/dev/null; then ${pkgs.procps}/bin/pkill -x orca; else ${pkgs.orca}/bin/orca; fi"; }
          Mod+C { close-window; }
          Mod+M { quit; }
          Mod+V { toggle-window-floating; }
          Mod+F { fullscreen-window; }
          Mod+P { switch-preset-column-width; }

          Print { screenshot; }
          Ctrl+Print { screenshot-screen; }

          Mod+Left  { focus-column-left; }
          Mod+Right { focus-column-right; }
          Mod+Up    { focus-window-up; }
          Mod+Down  { focus-window-down; }
          Mod+Shift+Left  { move-column-left; }
          Mod+Shift+Right { move-column-right; }
          Mod+Shift+Up    { move-window-up; }
          Mod+Shift+Down  { move-window-down; }

          Mod+1 { focus-workspace 1; }
          Mod+2 { focus-workspace 2; }
          Mod+3 { focus-workspace 3; }
          Mod+4 { focus-workspace 4; }
          Mod+5 { focus-workspace 5; }
          Mod+6 { focus-workspace 6; }
          Mod+7 { focus-workspace 7; }
          Mod+8 { focus-workspace 8; }
          Mod+9 { focus-workspace 9; }
          Mod+0 { focus-workspace 10; }
          Mod+Shift+1 { move-window-to-workspace 1; }
          Mod+Shift+2 { move-window-to-workspace 2; }
          Mod+Shift+3 { move-window-to-workspace 3; }
          Mod+Shift+4 { move-window-to-workspace 4; }
          Mod+Shift+5 { move-window-to-workspace 5; }
          Mod+Shift+6 { move-window-to-workspace 6; }
          Mod+Shift+7 { move-window-to-workspace 7; }
          Mod+Shift+8 { move-window-to-workspace 8; }
          Mod+Shift+9 { move-window-to-workspace 9; }
          Mod+Shift+0 { move-window-to-workspace 10; }

          Mod+WheelScrollDown cooldown-ms=150 { focus-workspace-down; }
          Mod+WheelScrollUp cooldown-ms=150 { focus-workspace-up; }

          XF86AudioRaiseVolume allow-when-locked=true { spawn "${pkgs.wireplumber}/bin/wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%+" "-l" "1.0"; }
          XF86AudioLowerVolume allow-when-locked=true { spawn "${pkgs.wireplumber}/bin/wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
          XF86AudioMute allow-when-locked=true { spawn "${pkgs.wireplumber}/bin/wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }
          XF86AudioMicMute allow-when-locked=true { spawn "${pkgs.wireplumber}/bin/wpctl" "set-mute" "@DEFAULT_AUDIO_SOURCE@" "toggle"; }
          XF86MonBrightnessUp allow-when-locked=true { spawn "${pkgs.brightnessctl}/bin/brightnessctl" "set" "5%+"; }
          XF86MonBrightnessDown allow-when-locked=true { spawn "${pkgs.brightnessctl}/bin/brightnessctl" "set" "5%-"; }
      }
    '';

    # The live image replaces this with its installer autostart declaration.
    "niri/live.kdl".text = "";

    "kitty/kitty.conf".text = ''
      font_family monospace
      font_size 11.0
      background #040718
      foreground #f2f4ff
      selection_background #6c55c9
      cursor #9d7cff
      window_padding_width 8
      confirm_os_window_close 0
    '';

    "mako/config".text = ''
      font=Noto Sans 11
      background-color=#070b20ee
      text-color=#f2f4ffff
      border-color=#9d7cffdd
      border-size=2
      border-radius=8
      default-timeout=5000
      width=360
      margin=12
      padding=12
    '';

    "wofi/config".text = ''
      show=drun
      width=520
      height=420
      location=center
      allow_images=true
      insensitive=true
      prompt=Search UmbraOS
    '';

    "wofi/style.css".text = ''
      window { margin: 0; border: 2px solid #9d7cff; border-radius: 12px; background-color: rgba(4, 7, 24, 0.97); font-family: "Noto Sans"; font-size: 14px; }
      #input { margin: 12px; padding: 10px; border-radius: 8px; color: #f2f4ff; background-color: #11183b; }
      #entry { padding: 8px 12px; border-radius: 8px; color: #c8cdef; }
      #entry:selected { color: #ffffff; background-color: #6c55c9; }
    '';

    "gtk-3.0/settings.ini".text = ''
      [Settings]
      gtk-theme-name=Adwaita-dark
      gtk-icon-theme-name=Papirus-Dark
      gtk-cursor-theme-name=Adwaita
      gtk-cursor-theme-size=24
      gtk-application-prefer-dark-theme=true
    '';

    "gtk-4.0/settings.ini".text = ''
      [Settings]
      gtk-theme-name=Adwaita-dark
      gtk-icon-theme-name=Papirus-Dark
      gtk-cursor-theme-name=Adwaita
      gtk-cursor-theme-size=24
      gtk-application-prefer-dark-theme=true
    '';

    "swaylock/config".text = ''
      daemonize
      screenshots
      clock
      indicator
      indicator-radius=108
      indicator-thickness=7
      effect-blur=10x5
      effect-vignette=0.35:0.35
      image=${wallpaper}
      scaling=fill
      font=Noto Sans
      font-size=22
      text-color=f2f4ffff
      inside-color=070b20cc
      ring-color=9d7cffdd
      key-hl-color=50b7f5ff
      line-color=00000000
      separator-color=00000000
      inside-ver-color=11183bdd
      ring-ver-color=50b7f5ff
      inside-wrong-color=2a0d24dd
      ring-wrong-color=ff6b8aff
    '';

    "waybar/config.jsonc".text = lib.mkForce (builtins.toJSON {
      layer = "top";
      position = "bottom";
      height = 44;
      spacing = 7;
      margin-bottom = 8;
      margin-left = 10;
      margin-right = 10;
      modules-left = [ "custom/umbra" "niri/workspaces" ];
      modules-center = [ "niri/window" ];
      modules-right = [ "pulseaudio" "network" "bluetooth" "battery" "clock" "tray" ];

      "custom/umbra" = {
        format = " ";
        tooltip = false;
        on-click = "${pkgs.wofi}/bin/wofi --show drun";
      };
      "niri/workspaces" = {
        format = "{icon}";
        format-icons = {
          active = "";
          default = "";
          urgent = "";
        };
        workspace-taskbar = {
          enable = true;
          icon-size = 19;
        };
      };
      "niri/window" = {
        format = "{title}";
        max-length = 64;
      };
      clock = {
        format = "󰥔  {:%I:%M %p}";
        format-alt = "󰃭  {:%a, %B %d}";
        tooltip-format = "<big>{:%B %Y}</big>\n<tt><small>{calendar}</small></tt>";
      };
      pulseaudio = {
        format = "{icon}  {volume}%";
        format-muted = "󰝟  muted";
        format-icons.default = [ "󰕿" "󰖀" "󰕾" ];
        on-click = "${pkgs.pavucontrol}/bin/pavucontrol";
      };
      network = {
        format-wifi = "󰖩  {essid}";
        format-ethernet = "󰈀  wired";
        format-disconnected = "󰖪  offline";
        tooltip-format = "{ifname}: {ipaddr}/{cidr}";
        on-click = "${pkgs.networkmanagerapplet}/bin/nm-connection-editor";
      };
      bluetooth = {
        format = "  {status}";
        format-disabled = "󰂲  disabled";
        format-off = "󰂲  off";
        format-on = "  on";
        format-connected = "  {device_alias}";
        tooltip-format = "Controller: {controller_alias}\nStatus: {status}";
        tooltip-format-connected = "{device_enumerate}";
        tooltip-format-enumerate-connected = "{device_alias}";
        on-click = "${pkgs.blueman}/bin/blueman-manager";
      };
      battery = {
        states = { warning = 30; critical = 15; };
        format = "{icon}  {capacity}%";
        format-charging = "󰂄  {capacity}%";
        format-icons = [ "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
      };
      tray.spacing = 8;
    });

    "waybar/style.css".text = lib.mkForce ''
      @define-color umbra-void #040718;
      @define-color umbra-panel rgba(7, 11, 32, 0.96);
      @define-color umbra-raised rgba(23, 31, 68, 0.92);
      @define-color umbra-violet #9d7cff;
      @define-color umbra-cyan #50b7f5;
      @define-color umbra-text #f2f4ff;
      @define-color umbra-muted #9aa4c7;
      @define-color umbra-danger #ff6b8a;

      * {
        border: none;
        border-radius: 0;
        min-height: 0;
        font-family: "Noto Sans", "Symbols Nerd Font";
        font-size: 13px;
      }

      window#waybar {
        color: @umbra-text;
        background: transparent;
      }

      window#waybar > box {
        background: linear-gradient(110deg, rgba(4, 7, 24, 0.97), rgba(15, 18, 55, 0.96));
        border: 1px solid rgba(157, 124, 255, 0.58);
        border-radius: 14px;
        box-shadow: 0 0 12px rgba(80, 183, 245, 0.16), inset 0 1px rgba(255, 255, 255, 0.04);
      }

      #custom-umbra {
        min-width: 30px;
        margin: 6px 2px 6px 8px;
        padding: 0 6px;
        border-radius: 9px;
        background-color: rgba(157, 124, 255, 0.12);
        background-image: url("${applicationButton}");
        background-repeat: no-repeat;
        background-position: center;
        background-size: 20px 20px;
        box-shadow: inset 0 0 0 1px rgba(157, 124, 255, 0.24);
      }

      #workspaces {
        margin: 5px 3px;
        padding: 1px 4px;
        border-radius: 10px;
        background: rgba(9, 14, 43, 0.84);
      }

      #workspaces button {
        min-width: 24px;
        margin: 1px 2px;
        padding: 0 7px;
        color: @umbra-muted;
        border-radius: 8px;
        background: transparent;
        transition: all 160ms ease;
      }

      #workspaces button.active {
        color: #ffffff;
        background: linear-gradient(135deg, #6c55c9, #473a99);
        box-shadow: inset 0 0 0 1px rgba(184, 179, 255, 0.38);
      }

      #workspaces button.urgent {
        color: #ffffff;
        background: @umbra-danger;
      }

      #workspaces button .niri-taskbar-btn {
        min-width: 26px;
        margin-left: 3px;
        padding: 0 4px;
        border-radius: 7px;
        background: rgba(80, 183, 245, 0.08);
      }

      #workspaces button .niri-taskbar-btn.focused {
        background: rgba(80, 183, 245, 0.26);
        box-shadow: inset 0 -2px @umbra-cyan;
      }

      #window {
        margin: 6px 8px;
        padding: 0 14px;
        color: #c8cdef;
        border-radius: 9px;
        background: rgba(17, 24, 59, 0.78);
      }

      #clock,
      #pulseaudio,
      #network,
      #bluetooth,
      #battery,
      #tray {
        margin: 6px 1px;
        padding: 0 10px;
        border-radius: 9px;
        color: #dce0ff;
        background: @umbra-raised;
        box-shadow: inset 0 0 0 1px rgba(157, 124, 255, 0.12);
      }

      #clock {
        margin-right: 2px;
        color: #ffffff;
        background: linear-gradient(135deg, rgba(108, 85, 201, 0.92), rgba(65, 54, 145, 0.92));
      }

      #tray { margin-right: 7px; }
      #pulseaudio.muted,
      #network.disconnected { color: @umbra-muted; }
      #battery.warning { color: #f4c76b; }
      #battery.critical { color: @umbra-danger; }

      tooltip {
        color: @umbra-text;
        background: @umbra-panel;
        border: 1px solid rgba(157, 124, 255, 0.62);
        border-radius: 10px;
      }
    '';
  };
}
