self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.wayland.windowManager.hyprland;
  defaultHyprlandPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    enableXWayland = cfg.xwayland.enable;
    hidpiXWayland = cfg.xwayland.hidpi;
    nvidiaPatches = cfg.nvidiaPatches;
    extraSessionCommands = cfg.extraSessionCommands;
  };
in {
  options.wayland.windowManager.hyprland = {
    enable = lib.mkEnableOption "hyprland wayland compositor";

    package = lib.mkOption {
      type = with lib.types; nullOr package;
      default = defaultHyprlandPackage;
      description = ''
        Hyprland package to use. Will override the 'xwayland' and 'extraSessionCommands' options.

        Defaults to the one provided by the flake. Set it to
        <literal>pkgs.hyprland</literal> to use the one provided by nixpkgs or
        if you have an overlay.

        Set to null to not add any Hyprland package to your path. This should
        be done if you want to use the NixOS module to install Hyprland.
      '';
    };

    systemdIntegration = lib.mkOption {
      type = lib.types.bool;
      default = pkgs.stdenv.isLinux;
      description = ''
        Whether to enable <filename>hyprland-session.target</filename> on
        hyprland startup. This links to <filename>graphical-session.target</filename>.
        Some important environment variables will be imported to systemd
        and dbus user environment before reaching the target, including
        <itemizedlist>
          <listitem><para><literal>DISPLAY</literal></para></listitem>
          <listitem><para><literal>WAYLAND_DISPLAY</literal></para></listitem>
          <listitem><para><literal>HYPRLAND_INSTANCE_SIGNATURE</literal></para></listitem>
          <listitem><para><literal>XDG_CURRENT_DESKTOP</literal></para></listitem>
        </itemizedlist>
      '';
    };

    # copied from HM modules/services/window-managers/i3-sway/sway.nix
    # Hopefully this fixes the significant problems arising from not having HM (and others)
    # sourced in the Hyprland env. (This is highly problematic when using app launchers instead of spawning apps from the terminal)
    extraSessionCommands = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        export SDL_VIDEODRIVER=wayland
        # needs qt5.qtwayland in systemPackages
        export QT_QPA_PLATFORM=wayland
        export QT_WAYLAND_DISABLE_WINDOWDECORATION="1"
        # Fix for some Java AWT applications (e.g. Android Studio),
        # use this if they aren't displayed properly:
        export _JAVA_AWT_WM_NONREPARENTING=1
      '';
      description = ''
        Shell commands executed just before Hyprland is started.
      '';
    };

    disableAutoreload = lib.mkOption {
      type = lib.types.bool;
      default = false;
      defaultText = lib.literalExpression "false";
      example = lib.literalExpression "true";
      description = ''
        Whether to disable automatically reloading Hyprland's configuration when
        rebuilding the Home Manager profile.
      '';
    };

    xwayland = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable XWayland.
        '';
      };
      hidpi = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable HiDPI XWayland.
        '';
      };
    };

    nvidiaPatches = lib.mkOption {
      type = lib.types.bool;
      default = false;
      defaultText = lib.literalExpression "false";
      example = lib.liberalExpression "true";
      description = ''
        Patch wlroots for better Nvidia support.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = "";
      description = ''
        Extra configuration lines to add to ~/.config/hypr/hyprland.conf.
      '';
    };

    recommendedEnvironment = lib.mkOption {
      type = lib.types.bool;
      default = true;
      defaultText = lib.literalExpression "true";
      example = lib.literalExpression "false";
      description = ''
        Whether to set the recommended environment variables.
      '';
    };

    # # this should probably be reversed, i.e. "add all except"
    # extraPropagatedEnvVars = lib.mkOption {
    #   type = with lib.types; listOf str;
    #   default = [];
    #   defaultText = lib.literalExpression "[]";
    #   description = ''
    #     Environment variables that should be imported to the session additional to the default ones
    #     (`[ "DISPLAY" "WAYLAND_DISPLAY" "HYPRLAND_INSTANCE_SIGNATURE" "XDG_CURRENT_DESKTOP" ]`).
    #     To have anything spawned in your graphical session working as you would expect (similar to when you execute it in a shell),
    #     you should probably add `PATH`, `SSH_AUTH_SOCK` () .... ***WIP***
    #   '';
    # };

    imports = [
      (
        lib.mkRenamedOptionModule
        ["wayland" "windowManager" "hyprland" "xwayland"]
        ["wayland" "windowManager" "hyprland" "xwayland" "enable"]
      )
    ];
  };

  config = lib.mkIf cfg.enable {
    home.packages =
      lib.optional (cfg.package != null) cfg.package
      ++ lib.optional cfg.xwayland.enable pkgs.xwayland;

    home.sessionVariables = lib.mkIf cfg.recommendedEnvironment {
      NIXOS_OZONE_WL = "1";
    };

    xdg.configFile."hypr/hyprland.conf" = lib.mkIf (cfg.extraConfig != null) {
      text =
        (lib.optionalString cfg.systemdIntegration ''
          exec-once=${pkgs.dbus}/bin/dbus-update-activation-environment --systemd --all && systemctl --user start hyprland-session.target
        '')
        + cfg.extraConfig;

      onChange = let
        hyprlandPackage =
          if cfg.package == null
          then defaultHyprlandPackage
          else cfg.package;
      in
        lib.mkIf (!cfg.disableAutoreload) ''(  # execute in subshell so that `shopt` won't affect other scripts
          shopt -s nullglob  # so that nothing is done if /tmp/hypr/ does not exist or is empty
          for instance in /tmp/hypr/*; do
            HYPRLAND_INSTANCE_SIGNATURE=''${instance##*/} ${hyprlandPackage}/bin/hyprctl reload config-only \
              || true  # ignore dead instance(s)
          done
        )'';
    };

    systemd.user.targets.hyprland-session = lib.mkIf cfg.systemdIntegration {
      Unit = {
        Description = "hyprland compositor session";
        Documentation = ["man:systemd.special(7)"];
        BindsTo = ["graphical-session.target"];
        Wants = ["graphical-session-pre.target"];
        After = ["graphical-session-pre.target" "gnome-keyring.service"]; # if using keyring, then start hyprland after it
      };
    };

    systemd.user.targets.tray = {
      Unit = {
        Description = "Home Manager System Tray";
        Requires = ["graphical-session-pre.target"];
      };
    };
  };
}
