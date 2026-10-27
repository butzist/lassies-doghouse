# Publish the jailed ColliePWA bridge on the tailnet with `tailscale serve`.
#
# This is the only part that touches Tailscale. It runs OUTSIDE the Collie
# jail, as root, and does exactly one thing: tell tailscaled to terminate TLS on
# the machine's MagicDNS name and forward to the loopback HTTP front door that
# this flake's home-manager module owns.
#
# Access is then https://<host>.<tailnet>.ts.net/ . Requirements in the Tailscale
# admin console: MagicDNS on, HTTPS certificates enabled, and an ACL that lets
# the phone reach this host on 443. Never use `tailscale funnel` here: funnel is
# public internet, serve is tailnet-only.
#
# The Collie user module must also allow the forwarded Host header. That is
# `services.collie.publicHosts = [ "<host>.<tailnet>.ts.net" ]` (the systemd
# proxy forwards the original Host, and Collie's host allowlist is fail-closed).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.collie-serve;
  inherit (lib) mkEnableOption mkIf mkOption types;

  # Same CLI the running tailscaled came from, so the LocalAPI version matches.
  tailscale = config.services.tailscale.package;

  # `tailscale serve --bg` persists the mapping in tailscaled, so the unit's job
  # is to set it once and then stay alive. Staying alive is also what gives us an
  # ExecStop that takes the mapping down again.
  start = pkgs.writeShellScript "collie-serve-start" ''
    set -eu
    ${tailscale}/bin/tailscale serve --bg --yes --https=${toString cfg.httpsPort} http://127.0.0.1:${toString cfg.port}
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';

  stop = pkgs.writeShellScript "collie-serve-stop" ''
    ${tailscale}/bin/tailscale serve --yes --https=${toString cfg.httpsPort} off || true
  '';
in {
  options.services.collie-serve = {
    enable = mkEnableOption "publishing ColliePWA on the tailnet with tailscale serve";

    port = mkOption {
      type = types.port;
      default = 8787;
      description = "The loopback port the home-manager module's socket proxy listens on.";
    };

    httpsPort = mkOption {
      type = types.port;
      default = 443;
      description = ''
        The HTTPS port tailscale serve listens on for this host. Keep 443 for
        the plain https://<host>.<tailnet>.ts.net/ URL; anything else needs the
        port in services.collie.publicHosts as well.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services.collie-serve = {
      description = "Publish ColliePWA on the tailnet (tailscale serve)";
      wantedBy = ["multi-user.target"];
      wants = ["tailscaled.service"];
      after = ["tailscaled.service"];
      # tailscaled may still be authenticating when this starts. Retry forever
      # rather than leaving the front door closed because boot won the race.
      startLimitIntervalSec = 0;
      startLimitBurst = 5;

      serviceConfig = {
        Type = "simple";
        ExecStart = start;
        ExecStop = stop;
        Restart = "on-failure";
        RestartSec = 15;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
