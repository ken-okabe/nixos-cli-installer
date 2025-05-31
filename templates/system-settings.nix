# /templates/system-settings.nix
#
# Configures basic system-wide settings such as time,
# internationalization (i18n), and console behavior.
{ lib, pkgs, config, hostname, ... }: # Added hostname to arguments
{

  time.timeZone = "Asia/Tokyo";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";
  services.xserver.layout = "us";

  # Set the system's hostname using the value passed from flake.nix
  networking.hostName = hostname; # Use the passed hostname argument

  networking.networkmanager.enable = true;
  hardware.bluetooth.enable = true;
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  virtualisation.virtualbox.host.enable = true;
  # Ensure the user passed from flake.nix is added to vboxusers if it's not a placeholder
  users.extraGroups.vboxusers.members = lib.optional (config.specialArgs.nixosUsername != "__NIXOS_USERNAME__") config.specialArgs.nixosUsername;

  networking.firewall.enable = false;
}