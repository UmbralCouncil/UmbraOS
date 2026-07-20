{ pkgs, ... }: {
  imports = [
    # Import any modules or take them out
    ../../modules/desktop/plasma.nix
    ../../modules/apps/software.nix
    ../../modules/commands/software.nix
    ../../modules/commands/shell.nix
    ../../modules/virt/core.nix
  ];
  # One line to change the kernel, comment out to use LTS
  # boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [ ];
  boot.blacklistedKernelModules = [ ];
}
