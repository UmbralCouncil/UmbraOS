{ pkgs, ... }:
let
  wallpaper = ../../assets/home_wallpaper.png;
  applicationButton = ../../assets/darkmode_application_button.svg;
in
{
  home.packages = with pkgs; [
    adwaita-icon-theme
    papirus-icon-theme
  ];

  home.pointerCursor = {
    gtk.enable = true;
    x11.enable = true;
    package = pkgs.adwaita-icon-theme;
    name = "Adwaita";
    size = 24;
  };

  xdg.configFile = {
    "hypr/hyprland.conf".text = ''
      # UmbraOS — deliberately close to the default Hyprland experience.
      monitor = ,preferred,auto,1

      exec-once = ${pkgs.hyprpaper}/bin/hyprpaper
      exec-once = ${pkgs.waybar}/bin/waybar
      exec-once = ${pkgs.mako}/bin/mako
      exec-once = ${pkgs.networkmanagerapplet}/bin/nm-applet --indicator
      exec-once = ${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent

      env = XCURSOR_SIZE,24
      env = XCURSOR_THEME,Adwaita
      env = HYPRCURSOR_SIZE,24
      env = GTK_THEME,Adwaita:dark
      exec-once = ${pkgs.hyprland}/bin/hyprctl setcursor Adwaita 24

      $mod = SUPER
      $terminal = ${pkgs.kitty}/bin/kitty
      $fileManager = ${pkgs.pcmanfm}/bin/pcmanfm
      $menu = ${pkgs.wofi}/bin/wofi --show drun

      input {
        kb_layout = us
        follow_mouse = 1
        sensitivity = 0

        touchpad {
          natural_scroll = false
          tap-to-click = true
        }
      }

      general {
        gaps_in = 5
        gaps_out = 10
        border_size = 2
        col.active_border = rgba(9d7cffcc) rgba(50b7f5cc) 45deg
        col.inactive_border = rgba(273253aa)
        resize_on_border = true
        layout = dwindle
      }

      decoration {
        rounding = 8
        active_opacity = 1.0
        inactive_opacity = 0.96

        shadow {
          enabled = true
          range = 12
          render_power = 3
          color = rgba(00000088)
        }

        blur {
          enabled = true
          size = 6
          passes = 2
          vibrancy = 0.15
        }
      }

      animations {
        enabled = true
        bezier = umbra, 0.22, 1, 0.36, 1
        animation = windows, 1, 5, umbra
        animation = windowsOut, 1, 4, default, popin 80%
        animation = border, 1, 7, default
        animation = fade, 1, 4, default
        animation = workspaces, 1, 5, umbra
      }

      misc {
        force_default_wallpaper = 0
        disable_hyprland_logo = true
      }

      # The live image replaces this empty file with its installer autostart.
      source = ~/.config/hypr/live.conf

      bind = $mod, Q, exec, $terminal
      bind = $mod, C, killactive
      bind = $mod, M, exit
      bind = $mod, E, exec, $fileManager
      bind = $mod, V, togglefloating
      bind = $mod, R, exec, $menu
      bind = $mod, P, pseudo
      bind = $mod, F, fullscreen
      bind = $mod, L, exec, ${pkgs.hyprlock}/bin/hyprlock
      bind = , PRINT, exec, ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" "$HOME/Pictures/Screenshot-$(date +%F-%H%M%S).png"

      bind = $mod, left, movefocus, l
      bind = $mod, right, movefocus, r
      bind = $mod, up, movefocus, u
      bind = $mod, down, movefocus, d

      bind = $mod, 1, workspace, 1
      bind = $mod, 2, workspace, 2
      bind = $mod, 3, workspace, 3
      bind = $mod, 4, workspace, 4
      bind = $mod, 5, workspace, 5
      bind = $mod, 6, workspace, 6
      bind = $mod, 7, workspace, 7
      bind = $mod, 8, workspace, 8
      bind = $mod, 9, workspace, 9
      bind = $mod, 0, workspace, 10

      bind = $mod SHIFT, 1, movetoworkspace, 1
      bind = $mod SHIFT, 2, movetoworkspace, 2
      bind = $mod SHIFT, 3, movetoworkspace, 3
      bind = $mod SHIFT, 4, movetoworkspace, 4
      bind = $mod SHIFT, 5, movetoworkspace, 5
      bind = $mod SHIFT, 6, movetoworkspace, 6
      bind = $mod SHIFT, 7, movetoworkspace, 7
      bind = $mod SHIFT, 8, movetoworkspace, 8
      bind = $mod SHIFT, 9, movetoworkspace, 9
      bind = $mod SHIFT, 0, movetoworkspace, 10

      bind = $mod, mouse_down, workspace, e+1
      bind = $mod, mouse_up, workspace, e-1
      bindm = $mod, mouse:272, movewindow
      bindm = $mod, mouse:273, resizewindow

      bindel = ,XF86AudioRaiseVolume, exec, ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
      bindel = ,XF86AudioLowerVolume, exec, ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
      bindl = ,XF86AudioMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
      bindl = ,XF86AudioMicMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
      bindel = ,XF86MonBrightnessUp, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%+
      bindel = ,XF86MonBrightnessDown, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%-
    '';

    "hypr/hyprpaper.conf".text = ''
      splash = false
      ipc = true

      wallpaper {
        monitor = *
        path = ${wallpaper}
        fit_mode = cover
      }
    '';

    "hypr/live.conf".text = "";

    "hypr/hyprlock.conf".text = ''
      general {
        disable_loading_bar = true
        hide_cursor = true
      }

      background {
        monitor =
        path = ${wallpaper}
        blur_passes = 3
        blur_size = 8
      }

      input-field {
        monitor =
        size = 320, 54
        outline_thickness = 2
        dots_size = 0.22
        outer_color = rgb(9d7cff)
        inner_color = rgba(070b20dd)
        font_color = rgb(f2f4ff)
        placeholder_text = <i>Password…</i>
        position = 0, -40
        halign = center
        valign = center
      }
    '';

    "waybar/config.jsonc".text = builtins.toJSON {
      layer = "top";
      position = "top";
      height = 34;
      spacing = 6;
      modules-left = [ "custom/umbra" "hyprland/workspaces" "hyprland/window" ];
      modules-center = [ "clock" ];
      modules-right = [ "pulseaudio" "network" "battery" "tray" ];

      "custom/umbra" = {
        format = " ";
        tooltip = false;
        on-click = "${pkgs.wofi}/bin/wofi --show drun";
      };
      "hyprland/workspaces" = {
        disable-scroll = false;
        all-outputs = true;
        format = "{name}";
      };
      "hyprland/window" = {
        max-length = 60;
        separate-outputs = true;
      };
      clock = {
        format = "{:%a %b %d  %I:%M %p}";
        tooltip-format = "<big>{:%B %Y}</big>\\n<tt><small>{calendar}</small></tt>";
      };
      pulseaudio = {
        format = "{icon} {volume}%";
        format-muted = "󰝟 muted";
        format-icons.default = [ "󰕿" "󰖀" "󰕾" ];
        on-click = "${pkgs.pavucontrol}/bin/pavucontrol";
      };
      network = {
        format-wifi = "󰖩 {essid}";
        format-ethernet = "󰈀 wired";
        format-disconnected = "󰖪 offline";
        tooltip-format = "{ifname}: {ipaddr}/{cidr}";
      };
      battery = {
        states = {
          warning = 30;
          critical = 15;
        };
        format = "{icon} {capacity}%";
        format-charging = "󰂄 {capacity}%";
        format-icons = [ "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
      };
      tray.spacing = 8;
    };

    "waybar/style.css".text = ''
      * {
        border: none;
        border-radius: 0;
        font-family: "Noto Sans", "Symbols Nerd Font";
        font-size: 13px;
        min-height: 0;
      }

      window#waybar {
        background: rgba(4, 7, 24, 0.94);
        color: #f2f4ff;
        border-bottom: 1px solid rgba(157, 124, 255, 0.45);
      }

      #custom-umbra {
        min-width: 28px;
        margin: 4px 4px 4px 8px;
        padding: 0 4px;
        background-image: url("${applicationButton}");
        background-repeat: no-repeat;
        background-position: center;
        background-size: 20px 20px;
      }

      #workspaces button {
        padding: 0 8px;
        color: #9aa4c7;
        background: transparent;
        border-radius: 7px;
        margin: 4px 1px;
      }

      #workspaces button.active {
        color: #ffffff;
        background: #6c55c9;
      }

      #workspaces button.urgent {
        background: #d75f87;
        color: #ffffff;
      }

      #window {
        color: #c8cdef;
        margin-left: 8px;
      }

      #clock,
      #pulseaudio,
      #network,
      #battery,
      #tray {
        padding: 0 10px;
        margin: 4px 1px;
        border-radius: 7px;
        background: rgba(23, 31, 68, 0.82);
      }

      #battery.warning {
        color: #f4c76b;
      }

      #battery.critical {
        color: #ff6b8a;
      }
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
      window {
        margin: 0;
        border: 2px solid #9d7cff;
        border-radius: 12px;
        background-color: rgba(4, 7, 24, 0.97);
        font-family: "Noto Sans";
        font-size: 14px;
      }
      #input {
        margin: 12px;
        padding: 10px;
        border-radius: 8px;
        color: #f2f4ff;
        background-color: #11183b;
      }
      #entry {
        padding: 8px 12px;
        border-radius: 8px;
        color: #c8cdef;
      }
      #entry:selected {
        color: #ffffff;
        background-color: #6c55c9;
      }
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
  };
}
