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

  # Shared helper: run gh as a given account WITHOUT touching hosts.yml.
  # `gh auth switch` rewrites ~/.config/gh/hosts.yml, and concurrent callers
  # corrupt it. Instead we read the account's token (read-only) and hand it to
  # this one process through GH_TOKEN. Never prints or logs the token.
  # Usage: _gh_exec_as <gh-binary> <username> [gh args...]
  ghExecAs = ''
    _gh_exec_as() {
      local gh_bin="$1" gh_user="$2"
      shift 2
      # Respect a token the caller already chose, and leave `gh auth
      # login/logout/switch/refresh/setup-git` on the stored credentials.
      case "''${1:-}:''${2:-}" in
        auth:login|auth:logout|auth:switch|auth:refresh|auth:setup-git) exec "$gh_bin" "$@" ;;
      esac
      if [[ -z "''${GH_TOKEN:-}" && -z "''${GITHUB_TOKEN:-}" && -n "$gh_user" ]]; then
        local gh_token
        gh_token="$("$gh_bin" auth token -u "$gh_user" 2>/dev/null)" || gh_token=""
        if [[ -n "$gh_token" ]]; then
          export GH_TOKEN="$gh_token"
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

      # Space-separated list of every configured account username, in priority
      # order, used by the `gh login` login-all handler below.
      loginUsernames = lib.concatMapStringsSep " " ({ value, ... }: value.username) sortedAccounts;

      # `gh login` (our own subcommand, not `gh auth login`) checks every
      # configured account and runs `gh auth login` for each one that isn't
      # already authenticated, so a single command brings the whole fleet up.
      loginAllSnippet = ''
        if [ "$1" = "login" ]; then
          shift
          echo "🔐 Checking all configured GitHub accounts…" >&2
          _gh_status="$(${lib.getExe cfg.defaultPackage} auth status 2>&1 || true)"
          _gh_missing=0
          for _gh_u in ${loginUsernames}; do
            if printf '%s\n' "$_gh_status" | grep -q "account $_gh_u "; then
              echo "  ✓ $_gh_u — already logged in" >&2
            else
              echo "" >&2
              echo "  → $_gh_u — NOT logged in. Starting login; authenticate as $_gh_u." >&2
              ${lib.getExe cfg.defaultPackage} auth login "$@"
              _gh_missing=$((_gh_missing + 1))
            fi
          done
          if [ "$_gh_missing" -eq 0 ]; then
            echo "✅ All configured accounts are already logged in." >&2
          else
            echo "✅ Logged in $_gh_missing account(s)." >&2
          fi
          exit 0
        fi
      '';

      # Generate the smart wrapper script
      smartWrapperScript = pkgs.writeShellScriptBin "gh" ''
        # GitHub CLI Multi-Account Smart Wrapper
        # Automatically picks the account based on current working directory

        ${generateMatchFunction}
        ${ghExecAs}

        # `gh login`: detect and log into every account that isn't authenticated.
        ${loginAllSnippet}

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
        (lib.attrValues wrappedPackages) ++
        (lib.flatten aliasPackages);
    }
  );
}
