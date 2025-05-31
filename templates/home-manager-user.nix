# /templates/home-manager-user.nix
#
# Home Manager configuration for the primary user.
{ pkgs, lib, config, inputs, username, gitUsername, gitUseremail, hostname, ... }: # Updated arguments

{
  home.stateVersion = "25.05";

  home.packages = with pkgs; [
    zsh-history-substring-search
    zsh-powerlevel10k
    git
  ];

  programs.home-manager.enable = true;

  programs.git = {
    enable = true;
    userName = gitUsername; # Use passed gitUsername
    userEmail = gitUseremail; # Use passed gitUseremail
    extraConfig = {
      init.defaultBranch = "main";
    };
  };

  programs.gh = {
    enable = true;
    extensions = with inputs.nixpkgs.legacyPackages.${pkgs.system}; [
      gh-markdown-preview # Assuming inputs.nixpkgs is available via specialArgs if gh is enabled
    ];
    settings = {
      editor = "nano";
      git_protocol = "ssh";
    };
  };

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    autocd = true;
    shellAliases = {
      ll = "ls -la -F --color=auto --group-directories-first";
      # Use the passed hostname argument
      update-system = "sudo nixos-rebuild switch --flake /etc/nixos#${hostname}";
    };
    initContent = ''
      export EDITOR=nano
      stty intr ^T
      if [ -f "${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme" ]; then
        source "${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme"
      fi
      if [[ -r "${config.home.homeDirectory}/.p10k.zsh" ]]; then
        source "${config.home.homeDirectory}/.p10k.zsh"
      fi
      local history_substring_search_path="${pkgs.zsh-history-substring-search}/share/zsh-history-substring-search/zsh-history-substring-search.zsh"
      if [ -f "$history_substring_search_path" ]; then
        source "$history_substring_search_path"
        bindkey "$terminfo[kcuu1]" history-substring-search-up
        bindkey "$terminfo[kcud1]" history-substring-search-down
      else
        echo "Warning: zsh-history-substring-search plugin not found at $history_substring_search_path" >&2
      fi
      export BUN_INSTALL="$HOME/.bun"
      export PATH="$BUN_INSTALL/bin:$PATH"
    '';
  };

  programs.ghostty = {
    enable = true;
    package = pkgs.ghostty;
    settings = {
      font-size = 12;
      background-opacity = 0.9;
      split-divider-color = "green";
      gtk-titlebar = true;
      keybind = [
        "ctrl+c=copy_to_clipboard"
        "ctrl+shift+c=copy_to_clipboard"
        "ctrl+shift+v=paste_from_clipboard"
        "ctrl+v=paste_from_clipboard"
        "ctrl+left=goto_split:left"
        "ctrl+down=goto_split:down"
        "ctrl+up=goto_split:up"
        "ctrl+right=goto_split:right"
        "ctrl+enter=new_split:down"
      ];
    };
    clearDefaultKeybinds = false;
    enableZshIntegration = true;
  };

  xdg.userDirs.enable = true;
  xdg.userDirs.createDirectories = true;

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      clock-format = "24h";
    };
    "org/gnome/shell/extensions/dash-to-panel" = {
      panel-position = "TOP";
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}