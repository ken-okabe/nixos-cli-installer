# /templates/virtualbox-guest.nix
{ config, lib, pkgs, nixosUsername, ... }: { # Added nixosUsername
  boot.initrd.availableKernelModules = [
    "ata_piix" "ohci_pci" "ehci_pci" "ahci" "sd_mod" "sr_mod"
    "virtio_pci" "virtio_scsi" "virtio_balloon" "virtio_net" "virtio_console"
  ];
  virtualisation.virtualbox.guest.enable = true;
  # Example for shared folders using the passed nixosUsername
  # virtualisation.virtualbox.guest.sharedFolders = {
  #   "myshare" = {
  #     mountPoint = "/media/sf_myshare";
  #     user = nixosUsername; # Use passed nixosUsername
  #   };
  # };
}