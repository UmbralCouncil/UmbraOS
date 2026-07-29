{
  description = "Starter NixOS flake.";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs@{ ... }: let
    baseSettings = {
      timeZone = "America/Chicago";        # Set your timezone
      hostName = "umbra";
      account = {
        name = "Umbra";
        hashedPassword = "$6$89mU305uYn2drBI4$8JuEj/ky8FJRlxzCs8Orb05i6rswJIxNaiNdg21o51s7qrO9VMF4/j8bWhvAnD.xDEiEYiBIe7VGHYquhEx42/";
      };
      /* We can set variables here and use them elsewhere. */
      /* Example: */
      /* myVar = "value"; */
    };
    # The graphical installer writes this file only into the target's private
    # flake copy. Normal source builds remain fully deterministic.
    installSettings =
      if builtins.pathExists ./installer-settings.nix
      then import ./installer-settings.nix
      else { };
    settings = inputs.nixpkgs.lib.recursiveUpdate baseSettings installSettings;
    system = "x86_64-linux";               # System architecture

    # Instantiate the unstable package set for this system so modules can
    # take `unstable` as an argument and pull individual packages from it,
    # e.g. `environment.systemPackages = [ unstable.somepackage ];`
    unstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };

    pkgs = import inputs.nixpkgs { inherit system; };
  in {

    # --- Contract check: the emitted catalog must match the vendored schema ---
    # schema/images-schema.json is the single source of truth for the
    # /etc/umbra/images.json contract (Umbra Studio vendors a byte-identical
    # copy). This validates the *value* of the catalog rather than the built
    # file, so it runs without realising the bundled image FODs — which means it
    # stays green while `sha256 = lib.fakeHash` (the release gate below is what
    # blocks shipping unpinned hashes; this check is purely about shape).
    checks.${system}.images-schema =
      let
        catalog = inputs.self.nixosConfigurations.umbra-live.config.umbra.labs.catalog;
        # unsafeDiscardStringContext: store_path carries a reference to the
        # bundled .drv; strip it so writing the file needs no build/fetch.
        catalogJson = pkgs.writeText "umbra-images.json"
          (builtins.unsafeDiscardStringContext (builtins.toJSON catalog));
      in
      pkgs.runCommand "images-schema-check"
        { nativeBuildInputs = [ pkgs.check-jsonschema ]; }
        ''
          check-jsonschema --schemafile ${./schema/images-schema.json} ${catalogJson}
          touch $out
        '';

    # --- Buildable artifacts -------------------------------------------------
    packages.${system} = {
      # The local HTML/CSS/JS installer and its constrained Bash backend.
      # Useful as a standalone artifact for UI/backend testing.
      installer = import ./installer {
        inherit pkgs;
        source = inputs.self;
        flakeInputs = inputs;
      };

      # The bootable UmbraOS live ISO. The live configuration imports the ISO
      # builder directly, so expose its native output rather than wrapping that
      # builder through the multi-image framework a second time.
      iso = inputs.self.nixosConfigurations.umbra-live.config.system.build.isoImage;

      # The emitted /etc/umbra/images.json, realisable on its own so Umbra Studio
      # can consume it as a test fixture without building or booting a system.
      # This is the exact derivation the installed system ships, so the fixture
      # is byte-identical to the on-disk file.
      images-json =
        inputs.self.nixosConfigurations.umbra-live.config.environment.etc."umbra/images.json".source;
    };

    # Having more than one configuration allows you to use the same
    # flake on multiple devices or for different purposes

    nixosConfigurations.default = inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs system settings unstable;
        isLive = false;
      };
      modules = [
        inputs.home-manager.nixosModules.home-manager
        ./profile/default/hardware.nix
        ./profile/default/configuration.nix
        ./compose.nix
      ];
    };
    nixosConfigurations.dev = inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs system settings unstable;
        isLive = false;
      };
      modules = [
        inputs.home-manager.nixosModules.home-manager
        ./profile/default/hardware.nix
        ./profile/default/configuration.nix
        ./profile/dev/configuration.nix
        ./compose.nix
      ];
    };
    nixosConfigurations.umbra-live = inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs system settings unstable;
        isLive = true;
      };
      modules = [
        inputs.home-manager.nixosModules.home-manager
        ./profile/iso/hardware.nix
        ./profile/iso/configuration.nix
        ./modules/iso
        ./modules/labs/images
        ./compose.nix
      ];
    };
  };
}
