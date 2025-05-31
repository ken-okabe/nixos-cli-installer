# /templates/fonts-ime.nix
#
# Configures the Input Method Editor (IME) for Japanese input (Fcitx5 + Mozc)
# and installs system-wide fonts.
{ pkgs, lib, ... }: {

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
    liberation_ttf
    fira-code # This is the standard Fira Code, not the Nerd Font version
              # If you want the Nerd Font version specifically, use nerd-fonts.fira-code below

    # Corrected Nerd Fonts:
    nerd-fonts.fira-code          # For FiraCode Nerd Font
    nerd-fonts.droid-sans-mono    # For DroidSansMono Nerd Font
    nerd-fonts.jetbrains-mono     # For JetBrainsMono Nerd Font

    # You can add other specific fonts you prefer, e.g.:
    # nerd-fonts.hack
    # nerd-fonts.ubuntu-mono
  ];

  fonts.fontconfig.enable = true;

  fonts.fontconfig.defaultFonts = {
    serif = [ "Liberation Serif" "Noto Serif" ];
    sansSerif = [ "Liberation Sans" "Noto Sans" ];
    # Adjust monospace to the correct Nerd Font names recognized by fontconfig
    # After rebuilding, check `fc-list | grep "FiraCode"` or similar to get the exact name
    monospace = [ "FiraCode Nerd Font Mono" "JetBrains Mono Nerd Font Mono" "Droid Sans Mono Nerd Font" "Liberation Mono" "Noto Sans Mono" ];
    emoji = [ "Noto Color Emoji" ];
  };

  # Japanese Input Method Editor (fcitx5 with Mozc)
  i18n.inputMethod = {
    enabled = "fcitx5"; # Enable Fcitx5 as the IME framework.
    fcitx5.addons = with pkgs; [
      fcitx5-mozc-ut      # Mozc engine for Japanese input.
      fcitx5-gtk          # GTK integration modules for Fcitx5.
      fcitx5-nord  
    ];
  };

  # Environment variables for Fcitx5 IME integration
  # These help applications (especially GTK and Qt ones) correctly discover
  # and use Fcitx5 as the input method.
  environment.sessionVariables = {
    GTK_IM_MODULE = "fcitx";
    QT_IM_MODULE = "fcitx";
    XMODIFIERS = "@im=fcitx";
    # INPUT_METHOD = "fcitx"; # Often covered by the above.
    # SDL_IM_MODULE = "fcitx"; # For SDL applications if IME is needed.
  };
}
