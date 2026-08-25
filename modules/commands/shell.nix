{ lib, pkgs, settings, isLive ? false, ... }:
{
  programs.zsh.enable = true;
  users.users.${if isLive then "nixos" else settings.account.name}.shell = pkgs.zsh;

  home-manager.users = lib.mkIf (!isLive) {
    ${settings.account.name} = {
    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      history = {
        size = 10000;
        save = 10000;
        ignoreDups = true;
        share = true;
      };
      shellAliases = {
        trash = "gio trash";
        ll = "ls -lah";
        gs = "git status --short --branch";
      };
      initContent = ''
        bindkey -e
        setopt AUTO_CD INTERACTIVE_COMMENTS

        umbra-rebuild() {
          local configuration="default"
          if [[ -f /etc/nixos/umbra/migration-settings.nix ]]; then
            configuration="umbra-migration"
          fi
          sudo nixos-rebuild switch --impure \
            --flake "/etc/nixos/umbra#$configuration"
        }

        proxied() {
          local ipq url port proxy_url

          print "zshrc: PROXIED.fn"
          sleep 1
          read -r "ipq?standard IP? (y/n): "
          if [[ $ipq == [yY] ]]; then
            url="192.168.49.1"
            print "setting proxy URL to http://$url"
          else
            read -r "url?enter proxy IP: "
          fi
          read -r "port?enter port: "

          proxy_url="http://$url:$port"
          export http_proxy="$proxy_url"
          export https_proxy="$proxy_url"
          export ssl_proxy="$proxy_url"
          export ftp_proxy="$proxy_url"
          export HTTP_PROXY="$proxy_url"
          export HTTPS_PROXY="$proxy_url"
        }
      '';
    };

    programs.starship = {
      enable = true;
      enableZshIntegration = true;
      settings = {
        add_newline = true;
        format = "$directory$git_branch$git_status$nix_shell$line_break$character";
        character = {
          success_symbol = "[❯](bold #9d7cff)";
          error_symbol = "[❯](bold red)";
        };
        directory.style = "bold #50b7f5";
        git_branch = {
          symbol = "󰘬 ";
          style = "bold #9d7cff";
        };
        nix_shell = {
          symbol = " ";
          style = "bold #50b7f5";
        };
      };
    };
    };
  };
}
