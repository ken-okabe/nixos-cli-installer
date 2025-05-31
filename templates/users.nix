# /templates/users.nix
#
# Configures system users, including the primary user account,
# password settings, and sudo privileges.
{ pkgs, lib, config, nixosUsername, passwordHash, ... }: # Added nixosUsername and passwordHash to arguments

{
  # Define the primary user account.
  users.users.${nixosUsername} = { # Use the passed nixosUsername argument
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    initialHashedPassword = passwordHash; # Use the passed passwordHash argument
  };

  # Set the root user's password to be the same as the primary user's password.
  users.users.root = {
    hashedPassword = passwordHash; # Use the passed passwordHash argument
  };

  # Configure sudo access.
  security.sudo = {
    wheelNeedsPassword = false;
  };

  programs.zsh.enable = true;
}
