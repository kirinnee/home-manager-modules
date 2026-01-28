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

  # Create a wrapped gh binary for an account
  createWrappedGh = name: accountCfg:
    let
      basePackage = if accountCfg.package != null then accountCfg.package else cfg.defaultPackage;
      ghBinary = lib.getExe basePackage;
    in
    pkgs.writeShellScriptBin "gh-${name}" ''
      # Switch to this account before executing
      ${ghBinary} auth switch -u "${accountCfg.username}" >/dev/null 2>&1
      exec ${ghBinary} "$@"
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
      description = "Alias definitions. Each alias creates a short command that appends flags to gh. For example, `ghi = "--repo $(git remote get-url origin)"` creates `ghi`, `ghi-personal`, `ghi-work`, etc.";
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
            description = "GitHub username for authentication switching";
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

      # Generate the smart wrapper script
      smartWrapperScript = pkgs.writeShellScriptBin "gh" ''
        # GitHub CLI Multi-Account Smart Wrapper
        # Automatically switches accounts based on current working directory

        ${generateMatchFunction}

        # Main execution
        username=$(_gh_match_account)

        # Show which account is being used
        if [[ -n "$username" ]]; then
          echo "🔐 Using GitHub account: $username" >&2
        fi

        # Switch to matched account, then execute
        ${lib.getExe cfg.defaultPackage} auth switch -u "$username" >/dev/null 2>&1
        exec ${lib.getExe cfg.defaultPackage} "$@"
      '';

      # Create alias packages for each alias
      # Each alias generates: {alias} (smart) and {alias}-{account} (direct)
      aliasPackages = lib.mapAttrsToList (aliasName: aliasFlags:
        let
          # Smart alias that uses directory matching
          smartAlias = pkgs.writeShellScriptBin aliasName ''
            ${generateMatchFunction}

            username=$(_gh_match_account)
            ${lib.getExe cfg.defaultPackage} auth switch -u "$username" >/dev/null 2>&1
            exec ${lib.getExe cfg.defaultPackage} "$@" ${aliasFlags}
          '';

          # Per-account aliases (direct)
          perAccountAliases = lib.mapAttrsToList (accountName: accountCfg:
            pkgs.writeShellScriptBin "${aliasName}-${accountName}" ''
              ${lib.getExe cfg.defaultPackage} auth switch -u "${accountCfg.username}" >/dev/null 2>&1
              exec ${lib.getExe cfg.defaultPackage} "$@" ${aliasFlags}
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
