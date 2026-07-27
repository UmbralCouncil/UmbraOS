{ inputs, pkgs, settings, isLive ? false, ... }: let
    # Bring in the unstable channel
    unstable = import inputs.nixpkgs-unstable { inherit (pkgs) system; };
    accountName = if isLive then "nixos" else settings.account.name;
in{
  # This line says what packages your user should have
  # installed, they aren't shared with root or other users
  home-manager.users.${accountName}.home.packages = with pkgs; [
    # Use the prefix 'unstable.' for unstable packages
    firefox
  ];
  # Check https://search.nixos.org/packages to see which packages are available
}
