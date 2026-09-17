{
  pkgs,
  lib,
  ...
}: let
  menu = ''

    PGZX development shell
    ======================

    Available commands:
      menu        - show this menu
      pglocal     - Create local installation from existing postgresql installation
      pguse       - Change default local installation to use
      pginit      - Initialize new test database in local installation
      pgstart     - Start local installation
      pgstop      - Stop local installation

    Shell aliases (might not work with direnv):
      root        - cd to project root
  '';

  makeScripts = scripts:
    lib.mapAttrsToList
    (name: script: pkgs.writeShellScriptBin name script)
    scripts;

  scripts = makeScripts {
    menu = ''
      cat <<EOF
      ${menu}
      EOF
    '';
  };

  # Supported PostgreSQL major versions. Only one `pg_config` can be on PATH
  # at a time, so the shell exposes a dispatcher that selects the version from
  # $PG_VERSION, falling back to out/.pgversion (written by `pguse`) and
  # finally to PostgreSQL 16.
  pgVersions = {
    "15" = pkgs.postgresql_15;
    "16" = pkgs.postgresql_16;
    "17" = pkgs.postgresql_17;
    "18" = pkgs.postgresql_18;
  };

  pgConfig = pkgs.writeShellScriptBin "pg_config" ''
    set -euo pipefail
    root="''${PRJ_ROOT:-$PWD}"
    version="''${PG_VERSION:-}"
    if [ -z "$version" ] && [ -r "$root/out/.pgversion" ]; then
      version="$(cat "$root/out/.pgversion")"
    fi
    case "''${version:-16}" in
      15) exec ${pkgs.postgresql_15.pg_config}/bin/pg_config "$@" ;;
      16) exec ${pkgs.postgresql_16.pg_config}/bin/pg_config "$@" ;;
      17) exec ${pkgs.postgresql_17.pg_config}/bin/pg_config "$@" ;;
      18) exec ${pkgs.postgresql_18.pg_config}/bin/pg_config "$@" ;;
      *)
        echo "pg_config: unsupported PostgreSQL version '$version' (supported: ${lib.concatStringsSep ", " (lib.attrNames pgVersions)})" >&2
        exit 1
        ;;
    esac
  '';
  # On darwin we expect command line tools to be installed.
  # It is possible to install clang/gcc as nix package, but linking
  # can be quite a pain.
  # On non-darwin systems we will use the nix toolchain for now.
  #useSystemCC = pkgs.stdenv.isDarwin;
in {
  packages =
    scripts
    ++ [
      # make linters and formatters available in dev shell
      pkgs.pre-commit
      pkgs.alejandra
      pkgs.deadnix
      pkgs.shellcheck
      pkgs.shfmt

      # Postgres tooling. `postgresql_NN_jit` is a withPackages/buildEnv wrapper
      # whose symlinked tree pglocal cannot relocate, so we use the plain
      # packages and pick one through the `pg_config` dispatcher above.
      pgConfig
      pkgs.openssl
      pkgs.gss
      pkgs.krb5
      pkgs.python3

      pkgs.pkg-config

      pkgs.zigpkgs.stable
      pkgs.zls
    ];

  shellHook = ''
    export PRJ_ROOT=$PWD
    export PG_HOME=$PRJ_ROOT/out/default
    export PATH="$PG_HOME/lib/postgresql/pgxs/src/test/regress:$PATH"
    export PATH="$PG_HOME/bin:$PRJ_ROOT/dev/bin:$PATH"

    # Nix postgres is patched to find and install libraries into another directory
    # than the default. For our local setup we must overwrite the default location by using
    # the NIX_PGLIBDIR environment variable.
    export NIX_PGLIBDIR=$PG_HOME/lib

    alias root='cd $PRJ_ROOT'

    menu
  '';
}
