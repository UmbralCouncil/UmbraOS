# Generic ARM64 UEFI/QEMU installation layout. The graphical installer replaces
# this with hardware detected on the target; there are no developer-machine UUIDs.
{ lib, ... }: {
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  boot.initrd.availableKernelModules = [ "xhci_pci" "virtio_pci" "virtio_blk" "virtio_scsi" "usbhid" "usb_storage" "sr_mod" ];
  fileSystems."/" = { device = "/dev/disk/by-label/UMBRA_ROOT"; fsType = "btrfs"; };
  fileSystems."/boot" = { device = "/dev/disk/by-label/UMBRA_EFI"; fsType = "vfat"; };
}
