# /templates/system-customizations.nix
{ pkgs, lib, config, ... }: { # No direct placeholder, but uses config.specialArgs implicitly if needed
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_zen;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nixpkgs.config.allowUnfree = true;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    download-buffer-size = 524288000;
    http-connections = 100;
    max-jobs = "auto";
  };
  virtualisation.virtualbox.host.enable = true;
  # Ensure the user passed from flake.nix is added to vboxusers if it's not a placeholder
  users.extraGroups.vboxusers.members = lib.optional (config.specialArgs.nixosUsername != "__NIXOS_USERNAME__") config.specialArgs.nixosUsername;
}