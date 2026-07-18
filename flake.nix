{
  description = "Starter NixOS flake.";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    lix-module = {
      url = "git+https://git.lix.systems/lix-project/nixos-module?ref=stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs@{ ... }: let
    settings = {
      timeZone = "America/Chicago";        # Set your timezone
      account.name = "name";               # Set your name
      /* We can set variables here and use them elsewhere. */
      /* Example: */
      /* myVar = "value"; */
    };
    system = "x86_64-linux";               # System architecture

    # Instantiate the unstable package set for this system so modules can
    # take `unstable` as an argument and pull individual packages from it,
    # e.g. `environment.systemPackages = [ unstable.somepackage ];`
    unstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {

    # Having more than one configuration allows you to use the same
    # flake on multiple devices or for different purposes

    nixosConfigurations.workstation = inputs.nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs system settings unstable; };
      modules = [
        inputs.home-manager.nixosModules.home-manager
        ./profile/workstation/hardware.nix
        ./profile/workstation/configuration.nix
        ./compose.nix
      ];
    };
    nixosConfigurations.home = inputs.nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs system settings unstable; };
      modules = [
        inputs.home-manager.nixosModules.home-manager
        ./profile/home/hardware.nix
        ./profile/home/configuration.nix
        ./compose.nix
      ];
    };
  };
}
