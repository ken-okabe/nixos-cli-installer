# /templates/gnome-desktop.nix
{ config, pkgs, lib, ... }:

{
  # 1. Enable the Xorg server
  services.xserver.enable = true;

  # 2. Enable the GNOME Display Manager (GDM)
  services.xserver.displayManager.gdm.enable = true;

  # 3. Enable the GNOME Desktop Environment
  services.xserver.desktopManager.gnome.enable = true;

  # 4. Configure OpenGL drivers
  # This is generally recommended for a good graphical experience.
  hardware.opengl.enable = true;

  # 5. Enable XWayland for running X11 applications on Wayland (GNOME's default)
  # This is often enabled by default when GNOME is enabled, but explicit is fine.
  programs.xwayland.enable = true;

  # Optional: Exclude certain default GNOME packages 
}