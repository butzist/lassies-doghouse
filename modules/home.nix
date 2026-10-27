# ColliePWA (https://github.com/AltanS/collie) as a jailed systemd --user
# service. This is the home-manager module of the `jailed-collie` flake.
#
# What the audit found it actually needs:
#
#   * the Herdr unix socket (~/.config/herdr/herdr.sock);
#   * its own settings under ~/.config/collie (commands.toml, keys.toml,
#     quick-replies.toml, launchers.toml, cache-rules.toml, theme.toml, fonts/);
#   * a writable state dir (~/.local/state/collie) for pairing, push
#     subscriptions, uploads, audit.log and the hook targets;
#   * read access to the web bundle and the binary, both in the (read-only)
#     Nix store.
#
# Optional, opt-in paths (off by default, because every one widens the blast
# radius if the web front is ever compromised):
#
#   readOnlyPaths = [
#     "%h/.local/share/opencode" # OpenCode session history
#     "%h/.claude/projects"      # Claude Code transcripts
#     "%h/.pi"                   # pi/omp session logs
#     "%h/src"                   # project folders, for Files/Changes
#   ];
#
# The network jail is a private network namespace with only `lo`: the bridge
# cannot open an outbound connection at all, DNS included. The host reaches it
# through a filesystem Unix socket in the state dir (Unix sockets cross network
# namespaces); `collie-http.socket` listens on host 127.0.0.1 and
# `systemd-socket-proxyd` relays into that socket, so the website is still
# plain HTTP. The jail never speaks TLS and never runs tailscale; on hosts that
# want tailnet access, this flake's `nixosModules.collie-serve` runs `tailscale
# serve` outside the jail and terminates HTTPS there.
#
# Web Push is the one deliberate exception, and it does not give the bridge a
# route: `web-push` is pointed at a loopback socket that relays into
# `packages/collie-push-proxy.py` on the host. That proxy accepts CONNECT only
# for the push-service hosts in `pushProxy.allowHosts`, so a hostile
# subscription endpoint still cannot make the bridge fetch arbitrary URLs.
#
# Self-update is impossible twice over: the store path is read-only, and the
# `herdr-plugin.toml` marker inside it makes `installKind` resolve to
# `packaged`, so `collie update` refuses before it touches anything. The
# network jail removes the download path as well.
#
# Pairing: after `systemctl --user start collie`, run `collie pair` from your
# shell (the CLI is installed below). It reads the state dir and talks to
# 127.0.0.1:<port> through the proxy. On a host that imports this flake's
# nixosModules.collie-serve, the QR points at
# https://<host>.<tailnet>.ts.net/; if the CLI cannot read tailscaled, run it as
#   COLLIE_PUBLIC_URL=https://<host>.<tailnet>.ts.net collie pair
# and enter the printed code in Settings.
#
# Herdr plugin: this deployment deliberately does NOT install `herdr.collie`.
# Herdr is only the multiplexer here; the bridge talks to HERDR_SOCKET_PATH
# directly. The upstream plugin action set belongs to `herdr plugin install`,
# which would create a second checkout and a competing service unit. Restart
# with `systemctl --user restart collie`, not
# `herdr plugin action invoke restart --plugin herdr.collie`.
{packageFor}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.collie;

  # Upstream's reference unit runs `bin/collie _exec-bridge`; `_exec-bridge`
  # skips the CLI's first-run/install/update paths and boots the bridge alone.
  inherit (cfg) package;

  port = toString cfg.port;

  # Only what the bridge actually shells out to. `git` powers the read-only
  # Changes view; coreutils covers the occasional `which`-style probe. There is
  # deliberately no tailscale, no systemd-run and no setsid here: the update
  # action cannot even reach for a supervisor.
  path = lib.makeBinPath ([pkgs.git pkgs.coreutils] ++ cfg.extraPackages);

  # The bridge's private network namespace cannot be reached from the host, and
  # `JoinsNamespaceOf=` is unreliable for user services (it needs
  # `PrivateNetwork=` on BOTH units and systemd's user-namespace ordering makes
  # the setns fail on many versions). A filesystem Unix socket crosses network
  # namespaces without any of that: collie's namespace listens on it, the host
  # proxy connects to it.
  bridgeSocket = "%S/collie/bridge.sock";
in {
  options.services.collie = {
    enable = lib.mkEnableOption "the ColliePWA bridge and its HTTP front door";

    package = lib.mkOption {
      type = lib.types.package;
      default = packageFor pkgs.stdenv.hostPlatform.system;
      defaultText = lib.literalExpression "jailed-collie.packages.\${pkgs.stdenv.hostPlatform.system}.collie";
      description = "The ColliePWA package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "Host port the HTTP front door listens on.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "100.64.0.5";
      description = ''
        Host address the HTTP front door listens on. The default keeps it on
        loopback (put `tailscale serve` or another reverse proxy in front). If
        you expose a tailnet/LAN address directly, also set
        `COLLIE_PUBLIC_HOSTS` to the exact Host header clients will send.
      '';
    };

    readOnlyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [
        "%h/.local/share/opencode"
        "%h/src"
      ];
      description = ''
        Extra host paths to bind into the jail read-only. Use the systemd `-`
        prefix for paths that may not exist. Agent session stores make the
        history views work; project folders make Files/Changes work.
      '';
    };

    readWritePaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["%h/src"];
      description = ''
        Extra host paths to bind into the jail read-write, e.g. a worktree root
        if the "new pane in a new worktree" flow should work.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Extra binaries to put on the bridge's PATH.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        COLLIE_PUBLIC_HOSTS = "host.tailnet.ts.net";
      };
      description = ''
        Extra environment for the bridge. These are appended after the jail's
        own settings, but they cannot widen the network or filesystem jail.
      '';
    };

    publicHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["legion.baboon-macaroni.ts.net"];
      description = ''
        Exact Host header(s) a reverse proxy will forward, written to
        COLLIE_PUBLIC_HOSTS. Collie's host allowlist is fail-closed, so a
        `tailscale serve` front door needs the MagicDNS name here (and the
        port too if it is not 443).
      '';
    };

    pushProxy = {
      enable = lib.mkEnableOption "allowlisted Web Push egress for the jailed bridge";

      allowHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "fcm.googleapis.com"
          "push.services.mozilla.com"
          "push.apple.com"
          "notify.windows.com"
        ];
        description = ''
          Host suffixes the host-side CONNECT proxy may reach on port 443.
          Web Push endpoints are supplied by the browser, so this is the
          allowlist that keeps the sender from becoming an arbitrary HTTPS
          client if a paired device registers a hostile subscription.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [package];

    systemd.user = {
      services = {
        collie = {
          Unit = {
            Description = "ColliePWA bridge (network- and filesystem-jailed)";
            After =
              ["default.target"]
              ++ lib.optional cfg.pushProxy.enable "collie-push-proxy.service";
            Wants = lib.optional cfg.pushProxy.enable "collie-push-proxy.service";
            # A phone-only operator cannot run `systemctl --user reset-failed`, so
            # never give up restarting (same choice as upstream's unit).
            StartLimitIntervalSec = 0;
          };

          Service = {
            Type = "simple";
            ExecStart = "${package}/bin/collie-bridge ${bridgeSocket} ${config.home.username}";
            WorkingDirectory = "${package}/lib/collie";
            Restart = "on-failure";
            RestartSec = 5;

            # ── network jail ────────────────────────────────────────────────
            # A fresh netns with only `lo`; no route, no DNS, no outbound socket
            # can succeed. The host reaches the bridge through the Unix socket
            # above, because Unix sockets are filesystem objects and cross
            # network namespaces.
            PrivateNetwork = true;
            RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK"];

            # ── filesystem jail ─────────────────────────────────────────────
            # Everything is read-only except the state dir. $HOME is an empty
            # tmpfs with three paths put back: settings, the Herdr socket dir,
            # and whatever the operator opts into through
            # readOnlyPaths/readWritePaths.
            ProtectSystem = "strict";
            ProtectHome = "tmpfs";
            PrivateTmp = true;
            PrivateMounts = true;
            StateDirectory = "collie";
            # Upstream creates its state dir with 0700 (it holds pairing tokens
            # and push endpoints). StateDirectory's default is 0755, so pin it.
            StateDirectoryMode = "0700";
            BindReadOnlyPaths =
              [
                "-%E/collie" # settings, read-only
                "-%E/herdr" # herdr.sock + named sessions, read-only
              ]
              ++ cfg.readOnlyPaths;
            BindPaths = cfg.readWritePaths;

            # ── no self-update, no phone-home ───────────────────────────────
            # `off` keeps the account-windows feature from reading the user's
            # Claude/OpenCode credentials and calling api.anthropic.com /
            # opencode.ai behind their back. The netns already blocks the call;
            # this keeps the bridge from trying.
            #
            # COLLIE_SKIP_SERVE keeps the bridge out of `tailscale serve`
            # entirely; this module publishes HTTP on host loopback only.
            Environment =
              [
                "HOME=%h"
                "PATH=${path}"
                "HERDR_SOCKET_PATH=%h/.config/herdr/herdr.sock"
                "HERDR_PLUGIN_CONFIG_DIR=%E/collie"
                "COLLIE_PLUGIN_ROOT=${package}/lib/collie"
                "COLLIE_STATE_DIR=%S/collie"
                "COLLIE_MUX=herdr"
                "COLLIE_HOST=127.0.0.1"
                "COLLIE_PORT=${port}"
                "COLLIE_SKIP_SERVE=1"
                "COLLIE_ACCOUNT_WINDOWS=off"
              ]
              ++ lib.optionals cfg.pushProxy.enable [
                # The bridge's web-push uses this as an HTTP CONNECT proxy.
                # The actual allowlist is enforced host-side; the jail only
                # ever sees the loopback relay started by collie-bridge.
                "COLLIE_PUSH_PROXY=http://127.0.0.1:3128"
              ]
              ++ lib.optionals (cfg.publicHosts != []) [
                "COLLIE_PUBLIC_HOSTS=${lib.concatStringsSep "," cfg.publicHosts}"
              ]
              ++ lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment;

            # ── process and kernel hardening ────────────────────────────────
            # No MemoryDenyWriteExecute: Bun/JSC needs W+X for its JIT.
            # No SystemCallFilter: Bun's runtime is too broad to whitelist safely.
            NoNewPrivileges = true;
            PrivateDevices = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
            CapabilityBoundingSet = "";
            AmbientCapabilities = "";
            UMask = "0077";
          };

          Install.WantedBy = ["default.target"];
        };

        # Web Push needs outbound HTTPS to the endpoint the browser chose.
        # Keeping that out of the bridge's netns means a paired device cannot
        # turn the sender into an arbitrary HTTPS client: this proxy runs on
        # the host, and its CONNECT handler is the allowlist. The jail reaches
        # it through a Unix socket in the shared state dir.
        collie-push-proxy = lib.mkIf cfg.pushProxy.enable {
          Unit = {
            Description = "ColliePWA Web Push egress proxy (allowlisted CONNECT)";
            After = ["default.target"];
            # Same reasoning as the bridge: a phone-only operator cannot
            # reset-failed, and push silently stopping is worse than a restart.
            StartLimitIntervalSec = 0;
          };

          Service = {
            Type = "simple";
            ExecStart = "${pkgs.python3}/bin/python3 ${../packages/collie-push-proxy.py} --socket %S/collie/push-proxy.sock${lib.optionalString (cfg.pushProxy.allowHosts != []) " --allow ${lib.concatStringsSep "," cfg.pushProxy.allowHosts}"}";
            Restart = "on-failure";
            RestartSec = 2;

            # No .pyc writes into the read-only store, and unbuffered journal
            # lines for the reject log.
            Environment = [
              "PYTHONDONTWRITEBYTECODE=1"
              "PYTHONUNBUFFERED=1"
            ];

            # The socket is a filesystem object in the state dir the bridge
            # already has mounted, so it crosses the network namespace.
            StateDirectory = "collie";
            StateDirectoryMode = "0700";
            UMask = "0077";

            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK"];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
            CapabilityBoundingSet = "";
            AmbientCapabilities = "";
          };

          Install.WantedBy = ["default.target"];
        };

        # The host-side half: the only socket that exists outside the jail. The
        # bridge's own 127.0.0.1:port lives inside its private netns; this
        # listener accepts on host loopback and relays to the bridge's Unix
        # socket, which crosses namespaces as a plain filesystem object.
        collie-http = {
          Unit = {
            Description = "ColliePWA HTTP front door (host loopback -> jail socket)";
            Requires = ["collie.service"];
            After = ["collie.service"];
          };

          Service = {
            Type = "simple";
            ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${bridgeSocket}";
            Restart = "on-failure";
            RestartSec = 2;

            # The only filesystem object it needs is the bridge socket.
            # ProtectSystem=strict already makes $HOME read-only; no
            # ProtectHome/bind layer is needed just to reach the socket.
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectClock = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            # The inherited listener is AF_INET; accept() needs no new socket.
            # Everything this process dials is AF_UNIX.
            RestrictAddressFamilies = ["AF_UNIX"];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
            CapabilityBoundingSet = "";
            AmbientCapabilities = "";
          };
        };
      };

      sockets.collie-http = {
        Socket = {
          ListenStream = "${cfg.listenAddress}:${port}";
          # One proxyd process multiplexes every connection (the default,
          # Accept=no); do not turn this into an Accept=yes per-connection unit.
        };
        Install.WantedBy = ["sockets.target"];
      };
    };
  };
}
