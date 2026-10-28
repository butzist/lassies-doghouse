# ColliePWA, built from source.
#
# The source is the tagged tree, so the binary we run is the code we audited.
# Dependencies come from the two `bun.lock` files through `bun2nix`, which
# prefetches every package as a fixed-output derivation. The real build runs
# `bun install` against that cache inside the network-less sandbox, with
# dependency lifecycle scripts disabled.
#
# Two trees, two derivations: the root (`cli/` + `bridge/`) compiles the Bun
# single-file executable, and `web/` builds the Vite bundle. The final package
# only assembles their outputs and the files the bridge reads at boot.
#
# One source patch (`collie-push-proxy.patch`) teaches `bridge/push.ts` to pass
# `COLLIE_PUSH_PROXY` to `web-push`'s per-send `proxy` option. The bridge's
# network namespace still has only `lo`; the proxy runs on the host and
# allowlists the push-service hosts.
#
# The source is currently AHEAD of upstream: the 1.24.1 tree plus the opencode
# 2.1 fixes from https://github.com/AltanS/collie/pull/607 and the fork's
# `feat/opencode-plugin` branch (an opencode plugin channel that reads session
# history over a Unix socket in the state dir), pinned by that branch's commit.
# When both land in an upstream tag, switch `owner` back to `AltanS` and `rev`
# to `tag = "vX.Y.Z"`.
#
# To bump the version:
#   1. change `version` and the `src` hash below (`nix-prefetch-url --unpack
#      https://github.com/AltanS/collie/archive/refs/tags/vX.Y.Z.tar.gz`, or
#      `.../archive/<rev>.tar.gz` for a fork commit);
#   2. from a checkout of that tag run
#        bun2nix -l bun.lock     -o /path/to/lassies-doghouse/packages/collie-bun.nix
#        (cd web && bun2nix -l bun.lock -o /path/to/lassies-doghouse/packages/collie-web-bun.nix)
#      using the pinned `bun2nix` from the dev shell. The two dependency sets
#      only change with the lockfiles, so a patch on the same lock reuses them.
#   3. re-apply `collie-push-proxy.patch` to the new tree (or re-spin it if
#      `bridge/push.ts` moved); `nix build .#collie` fails loudly if it no
#      longer applies, which is the point.
#
# The pinned Bun is 1.4.4, upstream's MIN_BUN (`cli/update-check.ts`). nixpkgs
# currently has 1.4.2, and `bun build --compile` copies the RUNNING bun into the
# output, so the override matters for the runtime the binary carries. Only the
# archive and version move; the rest of the derivation is nixpkgs'.
{
  lib,
  pkgs,
  stdenv,
  fetchFromGitHub,
  autoPatchelfHook,
  bun2nix,
}: let
  # 1.24.1 plus PR #607 (opencode 2.1 question dialogs and pre-upgrade history)
  # and the fork's opencode plugin history channel, taken from the branch until
  # upstream ships them.
  version = "1.24.1+plugin";

  src = fetchFromGitHub {
    owner = "butzist";
    repo = "collie";
    rev = "c36dab19d6e2ca8ba614e5b368cf23d8b42fbc9b";
    hash = "sha256-gXPmVkS0KVBbammZxcf4/Ae1yps/LTXNKA1YUkIRmiY=";
  };

  bun = pkgs.bun.overrideAttrs (finalAttrs: prevAttrs: {
    version = "1.4.4";
    # `src` is `passthru.sources.<system>`, one attribute down; nixpkgs'
    # heuristic only looks for a literal `src` and warns wrongly.
    __intentionallyOverridingVersion = true;
    passthru =
      prevAttrs.passthru
      // {
        sources = {
          "x86_64-linux" = pkgs.fetchurl {
            url = "https://github.com/oven-sh/bun/releases/download/bun-v${finalAttrs.version}/bun-linux-x64-baseline.zip";
            hash = "sha256-4ERutVmVdy65iUvrrppr42jZhai5Jx7hJEhvmUbu3XY=";
          };
          "aarch64-linux" = pkgs.fetchurl {
            url = "https://github.com/oven-sh/bun/releases/download/bun-v${finalAttrs.version}/bun-linux-aarch64.zip";
            hash = "sha256-uqa7NvUdblhWHgK76oJQOKnfRU9nPW13bou/hvjHhQ4=";
          };
          "aarch64-darwin" = pkgs.fetchurl {
            url = "https://github.com/oven-sh/bun/releases/download/bun-v${finalAttrs.version}/bun-darwin-aarch64.zip";
            hash = "sha256-wkDX8My5DCY6hJ/NsJt+5iYw2SE0jtaq/ahrnVd7xRA=";
          };
        };
      };
  });

  # The Vite bundle. `dontUseBunBuild` stops the hook's default `bun run build`;
  # we call Vite's JS entry point directly so a `#!/usr/bin/env node` shebang in
  # node_modules/.bin cannot depend on /usr/bin/env existing in the sandbox.
  web = stdenv.mkDerivation {
    pname = "collie-web";
    inherit version src;

    nativeBuildInputs = [bun2nix.hook bun];
    bunDeps = bun2nix.fetchBunDeps {bunNix = ./collie-web-bun.nix;};
    bunRoot = "web";

    dontUseBunBuild = true;
    dontRunLifecycleScripts = true;

    buildPhase = ''
      runHook preBuild
      (
        cd web
        export NODE_ENV=production
        ${bun}/bin/bun node_modules/vite/bin/vite.js build --outDir dist --emptyOutDir
      )
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R web/dist "$out/dist"
      runHook postInstall
    '';
  };

  # The Bun single-file executable. `cli/build.ts` and the release workflow run
  # exactly this command; the typecheck and version gate are release chores, not
  # artifact inputs.
  cli = stdenv.mkDerivation {
    pname = "collie-cli";
    inherit version src;

    # The only source change: `bridge/push.ts` learns `COLLIE_PUSH_PROXY`, so
    # the jailed bridge can hand Web Push to the host-side allowlisted CONNECT
    # proxy instead of needing a route to FCM/Mozilla/Apple.
    patches = [./collie-push-proxy.patch];

    nativeBuildInputs = [bun2nix.hook bun];
    bunDeps = bun2nix.fetchBunDeps {bunNix = ./collie-bun.nix;};

    dontUseBunBuild = true;
    dontRunLifecycleScripts = true;
    # The Bun bundle is appended to the ELF image; the default fixup strip
    # removes it and leaves a plain `bun` executable.
    dontStrip = true;

    buildPhase = ''
      runHook preBuild
      mkdir -p bin
      ${bun}/bin/bun build --compile --target=bun cli/main.ts --outfile bin/collie
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      cp bin/collie "$out/bin/collie"
      runHook postInstall
    '';
  };
  # The jail's entry point. It lives in the package (not in a separate
  # `writeShellScript` referenced only from the unit file) so `home.packages`
  # actually builds it. It runs inside the private network namespace:
  # `socat` turns the state-dir Unix socket into the bridge's loopback port, and
  # the host-side socket proxy dials that Unix socket.
  bridge = pkgs.writeShellScript "collie-bridge" ''
    set -u

    # Fail closed if systemd could not create the private network namespace
    # (some user-manager/userns combinations log and proceed without it). In
    # the real jail /sys/class/net holds exactly `lo`.
    ifaces="$(${pkgs.coreutils}/bin/ls /sys/class/net 2>/dev/null || true)"
    if [ "$ifaces" != "lo" ]; then
      echo "collie: private network namespace is missing; refusing to start" >&2
      exit 1
    fi

    socket="$1"
    ${pkgs.coreutils}/bin/rm -f "$socket"

    # Web Push egress: when the host-side allowlisted proxy is enabled, expose
    # its Unix socket on the jail's loopback so web-push can CONNECT through it.
    # The proxy socket sits beside the HTTP bridge socket in the state dir,
    # which is a filesystem object and therefore crosses network namespaces.
    push_pid=
    if [ -n "''${COLLIE_PUSH_PROXY:-}" ]; then
      push_socket="$(${pkgs.coreutils}/bin/dirname "$socket")/push-proxy.sock"
      (
        trap 'kill "''${push_child:-}" 2>/dev/null || true; exit 0' TERM INT
        # The proxy unit starts first, but a crash/restart can still race us.
        # Wait for its socket, then serve for the life of the bridge. A failed
        # per-connection CONNECT is reported to web-push and does not take the
        # bridge down.
        while [ ! -S "$push_socket" ]; do sleep 1; done
        while true; do
          ${pkgs.socat}/bin/socat \
            "TCP-LISTEN:3128,bind=127.0.0.1,fork,reuseaddr" \
            "UNIX-CONNECT:$push_socket" &
          push_child=$!
          wait "$push_child"
          sleep 1
        done
      ) &
      push_pid=$!
    fi

    ${pkgs.socat}/bin/socat \
      "UNIX-LISTEN:$socket,fork,reuseaddr,mode=0600,user=$2" \
      "TCP:127.0.0.1:''${COLLIE_PORT}" &
    socat_pid=$!

    "$(${pkgs.coreutils}/bin/dirname "$0")/collie" _exec-bridge &
    collie_pid=$!

    trap 'kill "$socat_pid" "$collie_pid" 2>/dev/null || true; [ -n "''${push_pid:-}" ] && kill "$push_pid" 2>/dev/null || true' TERM INT

    # Wait for the bridge or its HTTP relay. The push relay is auxiliary and
    # must not decide the unit's fate.
    set +e
    wait -n "$socat_pid" "$collie_pid"
    status=$?
    kill "$socat_pid" "$collie_pid" 2>/dev/null || true
    [ -n "''${push_pid:-}" ] && kill "$push_pid" 2>/dev/null || true
    wait
    exit "$status"
  '';
in
  stdenv.mkDerivation {
    pname = "collie";
    inherit version src;

    # The binary is a glibc-linked Bun executable. If it was compiled against
    # nixpkgs' patched bun, autoPatchelf rewrites the interpreter and rpath;
    # if nixpkgs already left them correct, this is a no-op. Darwin needs none
    # of it.
    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];

    dontConfigure = true;
    dontBuild = true;
    # The Bun bundle is appended to the ELF image; stripping breaks startup.
    dontStrip = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/lib/collie/bin" "$out/lib/collie/web" "$out/bin"
      cp ${cli}/bin/collie "$out/lib/collie/bin/collie"
      install -Dm755 ${bridge} "$out/bin/collie-bridge"
      cp -R ${web}/dist "$out/lib/collie/web/dist"
      cp herdr-plugin.toml package.json CHANGELOG.md LICENSE .env.example "$out/lib/collie/"
      # The OpenCode plugin is a loose JS file in the source tree (not part of
      # the compiled binary). Ship it so the home-manager module can install it
      # into ~/.config/opencode/plugins.
      cp -R plugins "$out/lib/collie/"
      ln -s "$out/lib/collie/bin/collie" "$out/bin/collie"

      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      test -f "$out/lib/collie/herdr-plugin.toml"
      test -f "$out/lib/collie/web/dist/index.html"
      test -f "$out/lib/collie/plugins/opencode/collie-opencode-bridge.js"
      echo "collie --version says: $("$out/bin/collie" --version)"
      runHook postInstallCheck
    '';

    meta = {
      description = "Phone web UI for the AI agents running in your terminal, served over Tailscale";
      homepage = "https://github.com/AltanS/collie";
      license = lib.licenses.mit;
      mainProgram = "collie";
      platforms = ["x86_64-linux" "aarch64-linux"];
    };
  }
