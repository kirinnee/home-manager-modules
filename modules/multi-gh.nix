{ config, lib, pkgs, ... }:

let
  cfg = config.programs.multi-gh;

  # Helper to expand ~ in directory rules
  expandHome = path: (
    if lib.hasPrefix "~" path
    then config.home.homeDirectory + lib.substring 1 (lib.stringLength path) path
    else path
  );

  # Sort accounts by priority (lower = higher priority, checked first)
  sortedAccounts = lib.sort
    (a: b: a.value.priority < b.value.priority)
    (lib.mapAttrsToList (name: value: { inherit name value; })
      (lib.filterAttrs (n: v: v.enable) cfg.accounts));

  # Generate the directory matching shell function
  generateMatchFunction = ''
    _gh_match_account() {
      local cwd="$PWD"

      ${lib.concatMapStringsSep "\n" ({ name, value }:
        lib.concatMapStringsSep "\n" (rule:
          let expanded = expandHome rule;
          in ''
      # Rule for ${name}: ${rule}
      if [[ "$cwd" == "${expanded}" || "$cwd" == "${expanded}/"* ]]; then
        echo "${value.username}"
        return 0
      fi''
        ) value.directoryRules
      ) sortedAccounts}

      # Fallback to default account
      echo "${cfg.accounts.${cfg.defaultAccount}.username}"
    }
  '';

  # Shared helper: run gh as a given account, normally WITHOUT touching
  # hosts.yml. `gh auth switch` rewrites ~/.config/gh/hosts.yml, and concurrent
  # callers corrupt it. Instead we read the account's token (read-only) and hand
  # it to this one process: GH_TOKEN for github.com and *.ghe.com (GitHub
  # Enterprise Cloud; token looked up with --hostname "$GH_HOST"), and
  # GH_ENTERPRISE_TOKEN for any OTHER GH_HOST (GitHub Enterprise Server; gh
  # ignores GH_TOKEN there). A token already set by the caller wins
  # (GH_TOKEN/GITHUB_TOKEN, or GH_ENTERPRISE_TOKEN/GITHUB_ENTERPRISE_TOKEN for
  # the enterprise case). Never prints or logs the token.
  # LIMITATION: the host is only taken from an explicit GH_HOST. If GH_HOST is
  # unset, or the host is inferred from a repo remote or a --hostname flag, the
  # token lookup targets gh's default host (github.com), so the account is only
  # matched there. Set GH_HOST for GitHub Enterprise Server (unchanged from
  # before for inferred hosts).
  # Exception: `gh auth refresh` and `gh auth logout` act on the stored ACTIVE
  # account, so for those two (rare, manual) we still run `gh auth switch`
  # first. login/switch/setup-git are plain pass-through.
  # Usage: _gh_exec_as <gh-binary> <username> [gh args...]
  ghExecAs = ''
    _gh_exec_as() {
      local gh_bin="$1" gh_user="$2"
      shift 2
      case "''${1:-}:''${2:-}" in
        auth:refresh|auth:logout)
          [[ -n "$gh_user" ]] && "$gh_bin" auth switch -u "$gh_user" >/dev/null 2>&1
          exec "$gh_bin" "$@" ;;
        auth:login|auth:switch|auth:setup-git) exec "$gh_bin" "$@" ;;
      esac
      local gh_host="''${GH_HOST:-}" gh_token_var=GH_TOKEN gh_have_token=""
      local -a gh_host_args=()
      case "$gh_host" in
        ""|github.com) ;;
        *.ghe.com) gh_host_args=(--hostname "$gh_host") ;;
        *) gh_token_var=GH_ENTERPRISE_TOKEN; gh_host_args=(--hostname "$gh_host") ;;
      esac
      if [[ "$gh_token_var" == GH_ENTERPRISE_TOKEN ]]; then
        [[ -n "''${GH_ENTERPRISE_TOKEN:-}" || -n "''${GITHUB_ENTERPRISE_TOKEN:-}" ]] && gh_have_token=1
      else
        [[ -n "''${GH_TOKEN:-}" || -n "''${GITHUB_TOKEN:-}" ]] && gh_have_token=1
      fi
      if [[ -z "$gh_have_token" && -n "$gh_user" ]]; then
        local gh_token
        gh_token="$("$gh_bin" auth token -u "$gh_user" "''${gh_host_args[@]}" 2>/dev/null)" || gh_token=""
        if [[ -n "$gh_token" ]]; then
          export "$gh_token_var=$gh_token"
        else
          echo "multi-gh: could not read a token for account '$gh_user'; using gh's active account" >&2
        fi
      fi
      exec "$gh_bin" "$@"
    }
  '';

  # Create a wrapped gh binary for an account
  createWrappedGh = name: accountCfg:
    let
      basePackage = if accountCfg.package != null then accountCfg.package else cfg.defaultPackage;
      ghBinary = lib.getExe basePackage;
    in
    pkgs.writeShellScriptBin "gh-${name}" ''
      ${ghExecAs}
      # Run as this account (per process, no hosts.yml rewrite)
      _gh_exec_as ${ghBinary} "${accountCfg.username}" "$@"
    '';

in
{
  options.programs.multi-gh = {
    enable = lib.mkEnableOption "GitHub CLI Multi-Account manager";

    defaultPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.gh;
      description = "Default GitHub CLI package to use";
    };

    defaultAccount = lib.mkOption {
      type = lib.types.str;
      description = "Default account when CWD doesn't match any rules (must exist in accounts)";
    };

    smartWrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create smart `gh` wrapper that auto-detects account";
      };
    };

    shellIntegration = {
      functions = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create `gh-<name>` shell functions for each account";
      };

      showActive = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add `_gh_active_account()` function for shell prompts";
      };
    };

    aliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Alias definitions. Each alias creates a short command that appends flags to gh. For example, `ghi = \"--repo \$(git remote get-url origin)\"` creates `ghi`, `ghi-personal`, `ghi-work`, etc.";
    };

    accounts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable this account";
          };

          priority = lib.mkOption {
            type = lib.types.int;
            default = 100;
            description = "Priority for directory rule matching (lower = checked first). Use this to ensure specific directories match before general ones.";
          };

          username = lib.mkOption {
            type = lib.types.str;
            description = "GitHub username whose token is used for this account (read per process via `gh auth token -u`; hosts.yml is never rewritten)";
          };

          directoryRules = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Directory patterns that trigger this account (supports ~ for home). More specific paths should be in higher-priority accounts.";
          };

          package = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            description = "Override package for this account";
          };
        };
      }));
      default = { };
      description = "Per-account configurations";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      enabledAccounts = lib.filterAttrs (n: v: v.enable) cfg.accounts;
      accountNames = lib.attrNames enabledAccounts;

      # Create wrapped packages for each account
      wrappedPackages = lib.mapAttrs createWrappedGh enabledAccounts;

      # Quoted account names and usernames (parallel lists, so any character in
      # a name is safe), in priority order.
      loginAccountNames = lib.concatMapStringsSep " "
        ({ name, ... }: lib.escapeShellArg name)
        sortedAccounts;
      loginAccountUsers = lib.concatMapStringsSep " "
        ({ value, ... }: lib.escapeShellArg value.username)
        sortedAccounts;

      # `gh-login-all`: log into every configured account in one go, or just one
      # with `--account <name>`. For each account it checks the stored login
      # read-only (`gh auth token -u`, output discarded), and only for a missing
      # one runs `gh auth login` (browser), then verifies the right user logged
      # in. `gh auth login` adds a user and rewrites hosts.yml: fine for this
      # rare, manual, one-person command. Never prints or logs a token.
      loginAllScript = pkgs.writeShellScriptBin "gh-login-all" ''
        # Log into every configured GitHub account (or one, with --account).
        gh_bin=${lib.getExe cfg.defaultPackage}
        gh_host=github.com
        names=(${loginAccountNames})
        users=(${loginAccountUsers})

        usage() {
          echo "usage: gh-login-all [--account <name>]" >&2
          echo "accounts: ''${names[*]}" >&2
        }

        only=""
        have_only=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --account) [[ $# -ge 2 ]] || { usage; exit 2; }; only="$2"; have_only=1; shift 2 ;;
            --account=*) only="''${1#--account=}"; have_only=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "gh-login-all: unknown argument '$1'" >&2; usage; exit 2 ;;
          esac
        done

        if [[ -n "$have_only" ]]; then
          found=""
          for n in "''${names[@]}"; do [[ "$n" == "$only" ]] && found=1; done
          [[ -n "$found" ]] || { echo "gh-login-all: no such account '$only'" >&2; usage; exit 2; }
        fi

        # gh with no ambient token/host: an env token would make `auth login`
        # refuse and `auth token` return the wrong thing.
        # GH_DEBUG=api would trace OAuth response bodies (tokens) during login.
        gh_clean() {
          env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_HOST -u GH_DEBUG -u DEBUG \
            "$gh_bin" "$@"
        }
        # True when this user is stored. The token goes to /dev/null, never to the screen.
        has_login() { gh_clean auth token --hostname "$gh_host" -u "$1" >/dev/null 2>&1; }

        summary=()
        failed=0
        for i in "''${!names[@]}"; do
          name="''${names[$i]}"
          user="''${users[$i]}"
          [[ -z "$have_only" || "$only" == "$name" ]] || continue

          if has_login "$user"; then
            echo "$name: already logged in"
            summary+=("$name: already logged in")
            continue
          fi

          echo "$name: log in as $user in the browser now"
          if ! gh_clean auth login --hostname "$gh_host" --git-protocol https --web; then
            echo "$name: login did not finish" >&2
            summary+=("$name: FAILED (login did not finish)")
            failed=1
            continue
          fi

          if has_login "$user"; then
            summary+=("$name: logged in")
          else
            # The new login is gh's active account; ask who it is (login name only).
            actual="$(gh_clean api user --jq .login 2>/dev/null)" || actual=""
            if [[ -n "$actual" ]]; then
              echo "$name: you logged in as $actual, expected $user; run gh-login-all again" >&2
              summary+=("$name: FAILED (logged in as $actual, expected $user)")
            else
              echo "$name: could not confirm a login for $user; run gh-login-all again" >&2
              summary+=("$name: FAILED (no login for $user)")
            fi
            failed=1
          fi
        done

        echo
        echo "Summary:"
        for line in "''${summary[@]}"; do echo "  $line"; done
        exit "$failed"
      '';

      # Generate the smart wrapper script
      smartWrapperScript = pkgs.writeShellScriptBin "gh" ''
        # GitHub CLI Multi-Account Smart Wrapper
        # Automatically picks the account based on current working directory

        ${generateMatchFunction}
        ${ghExecAs}

        # `gh login`: shorthand for `gh-login-all` (log into every configured account).
        if [[ "''${1:-}" == "login" ]]; then
          shift
          exec ${lib.getExe loginAllScript} "$@"
        fi

        # Main execution
        username=$(_gh_match_account)

        # Show which account is being used
        if [[ -n "$username" ]]; then
          echo "🔐 Using GitHub account: $username" >&2
        fi

        # Run as the matched account (per process, no hosts.yml rewrite)
        _gh_exec_as ${lib.getExe cfg.defaultPackage} "$username" "$@"
      '';

      # Create alias packages for each alias
      # Each alias generates: {alias} (smart) and {alias}-{account} (direct)
      aliasPackages = lib.mapAttrsToList (aliasName: aliasFlags:
        let
          # Smart alias that uses directory matching
          smartAlias = pkgs.writeShellScriptBin aliasName ''
            ${generateMatchFunction}

            ${ghExecAs}

            username=$(_gh_match_account)
            _gh_exec_as ${lib.getExe cfg.defaultPackage} "$username" "$@" ${aliasFlags}
          '';

          # Per-account aliases (direct)
          perAccountAliases = lib.mapAttrsToList (accountName: accountCfg:
            pkgs.writeShellScriptBin "${aliasName}-${accountName}" ''
              ${ghExecAs}

              _gh_exec_as ${lib.getExe cfg.defaultPackage} "${accountCfg.username}" "$@" ${aliasFlags}
            ''
          ) enabledAccounts;
        in
        [ smartAlias ] ++ perAccountAliases
      ) cfg.aliases;

    in
    {
      # Assertions
      assertions = [
        {
          assertion = cfg.defaultAccount != "" && lib.hasAttr cfg.defaultAccount cfg.accounts;
          message = "programs.multi-gh.defaultAccount must reference an existing account. Got '${cfg.defaultAccount}' but available accounts are: ${lib.concatStringsSep ", " accountNames}";
        }
        {
          assertion = !(lib.elem "login-all" accountNames);
          message = "programs.multi-gh: an account named 'login-all' would collide with the gh-login-all command";
        }
        {
          assertion = accountNames != [ ];
          message = "programs.multi-gh requires at least one account to be defined";
        }
      ];

      # Shell integration: functions and prompt helper
      programs.zsh.initContent = lib.mkIf (config.programs.zsh.enable && (cfg.shellIntegration.functions || cfg.shellIntegration.showActive)) (
        let
          # Shell functions (alternative to binaries)
          functionDefs = lib.optionalString cfg.shellIntegration.functions (
            lib.concatStringsSep "\n" (lib.mapAttrsToList
              (name: accountCfg: ''
                gh-${name}() {
                  ${lib.getExe wrappedPackages.${name}} "$@"
                }
              '')
              enabledAccounts)
          );

          # Prompt integration function
          activeFunction = lib.optionalString cfg.shellIntegration.showActive ''
            ${generateMatchFunction}

            _gh_active_account() {
              local username=$(_gh_match_account)
              local defaultUsername="${cfg.accounts.${cfg.defaultAccount}.username}"
              if [[ -n "$username" && "$username" != "$defaultUsername" ]]; then
                echo "[$username]"
              fi
            }
          '';
        in
        lib.mkAfter (functionDefs + activeFunction)
      );

      # Add smart wrapper, wrapped packages, and aliases
      home.packages =
        (lib.optionals cfg.smartWrapper.enable [ smartWrapperScript ]) ++
        [ loginAllScript ] ++
        (lib.attrValues wrappedPackages) ++
        (lib.flatten aliasPackages);
    }
  );
}
