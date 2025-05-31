# /etc/nixos/rdp-display-prerequisites.nix
{ config, pkgs, lib, nixosUsername, ... }:

{
  
  users.groups.rdpapp = {}; # 新しいグループ "rdpapp" を定義

  boot.kernelModules = [ "uinput" ];

  services.udev.extraRules = ''
    KERNEL=="uinput", MODE="0660", GROUP="rdpapp", OPTIONS+="static_node=uinput"
  '';

  users.users.${nixosUsername}.extraGroups = [ "input" "video" "audio" "wheel" "rdpapp" ]; # "rdpapp" を追加

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    audio.enable = true;
    pulse.enable = true;
  };
}