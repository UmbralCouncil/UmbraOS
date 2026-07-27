{ pkgs, ... }: {
  # VS Code is unfree; this developer profile deliberately permits it.
  nixpkgs.config.allowUnfree = true;

  users.users.umbradev = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" ];
    # Development-only default password: "umbradev".
    hashedPassword = "$6$icZY8lbF73dG9MiC$mhFZCOTqLI5.hD0f20WQd/wCcRpPONw.i/pzszLMwVF9a9oY10tYHPIQ6h89Ci77n66NHTiCLyoDR0CzQEaGx1";
  };

  environment.systemPackages = with pkgs; [
    codex
    git
    vscode
    wget
  ];
}
