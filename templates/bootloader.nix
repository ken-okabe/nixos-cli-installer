# /templates/bootloader.nix
#
# Configures the system bootloader.
{ pkgs, lib, config, targetDiskForGrub, ... }: # Added targetDiskForGrub to arguments

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # --- GRUB Configuration (Alternative, if preferred or for BIOS systems) ---
  # boot.loader.grub = {
  #   enable = true;
  #   device = targetDiskForGrub; # Use the passed targetDiskForGrub argument
  #   efiSupport = true;
  #   canTouchEfiVariables = true;
  #   useOSProber = false;
  # };
  # boot.loader.systemd-boot.enable = lib.mkForce false;
}