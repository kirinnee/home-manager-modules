{ config, lib, pkgs, ... }:

let
  cfg = config.programs.multi-codex;
  tomlFormat = pkgs.formats.toml { };

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

  # Get config directory name for an account
  getConfigDir = name: accountCfg:
    if accountCfg.configDirName != null
    then ".codex-${accountCfg.configDirName}"
    else ".codex-${name}";

  # Create a wrapped codex binary for an account
  createWrappedCodex = name: accountCfg:
    let
      basePackage = if accountCfg.package != null then accountCfg.package else cfg.defaultPackage;
      codexBinary = lib.getExe basePackage;
      configDir = getConfigDir name accountCfg;
      envExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "export ${k}=${v}") accountCfg.env
      );
    in
    pkgs.writeShellScriptBin "codex-${name}" ''
      export CODEX_HOME="$HOME/${configDir}"
      ${envExports}
      exec ${codexBinary} "$@"
    '';

  # Generate the directory matching shell function (single source of truth)
  generateMatchFunction = ''
    _codex_match_account() {
      local cwd="$PWD"

      ${lib.concatMapStringsSep "\n" ({ name, value }:
        lib.concatMapStringsSep "\n" (rule:
          let expanded = expandHome rule;
          in ''
      # Rule for ${name}: ${rule}
      if [[ "$cwd" == "${expanded}" || "$cwd" == "${expanded}/"* ]]; then
        echo "${name}"
        return 0
      fi''
        ) value.directoryRules
      ) sortedAccounts}

      # Fallback to default account
      echo "${cfg.defaultAccount}"
    }
  '';

in
{
  options.programs.multi-codex = {
    enable = lib.mkEnableOption "Codex CLI Multi-Account manager";

    defaultPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.codex;
      description = "Default Codex CLI package to use";
    };

    defaultAccount = lib.mkOption {
      type = lib.types.str;
      description = "Default account when CWD doesn't match any rules (must exist in accounts)";
    };

    smartWrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create smart `codex` wrapper that auto-detects account";
      };
    };

    shellIntegration = {
      functions = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create `<name>-codex` shell functions for each account";
      };

      showActive = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add `_codex_active_account()` function for shell prompts";
      };
    };

    aliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''Alias definitions. Each alias creates a short command that appends arguments to codex. For example, `cx = "--full-auto"` creates `cx`, `cx-personal`, `cx-work`, etc.'';
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
            description = "Priority for directory rule matching (lower = checked first)";
          };

          configDirName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Override the config directory name. Defaults to account name. Config will be at ~/.codex-<configDirName>";
          };

          directoryRules = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Directory patterns that trigger this account (supports ~ for home)";
          };

          package = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            description = "Override package for this account";
          };

          settings = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "Codex CLI config.toml content (model, model_provider, approval_policy, etc.)";
          };

          mcpServers = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "MCP server configurations (mapped to [mcp_servers] in config.toml)";
          };

          memory = {
            text = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Inline AGENTS.md content";
            };

            source = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "AGENTS.md file path to copy";
            };
          };

          skills = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "Inline skill files/directories (attrset of path => content or dir). Placed in .agents/skills/";
          };

          skillsDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of skill files to symlink into .agents/skills/";
          };

          hooksConfig = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "hooks.json content (event matchers and handler commands)";
          };

          hooks = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Inline hook scripts (attrset of filename => content). Will be made executable.";
          };

          hooksDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of hook scripts to symlink";
          };

          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Environment variables to export before running codex binary. Supports shell expansion.";
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
      wrappedPackages = lib.mapAttrs createWrappedCodex enabledAccounts;

      # Generate the smart wrapper script
      smartWrapperScript = pkgs.writeShellScriptBin "codex" ''
        # Codex Multi-Account Smart Wrapper
        # Automatically switches accounts based on current working directory

        ${generateMatchFunction}

        # Main execution
        account=$(_codex_match_account)

        # Show which account is being used
        if [[ -n "$account" ]]; then
          echo "Using Codex account: $account" >&2
        fi

        case "$account" in
          ${lib.concatMapStringsSep "\n" ({ name, value }: ''
          "${name}")
            exec ${lib.getExe wrappedPackages.${name}} "$@"
            ;;''
          ) sortedAccounts}
          *)
            # Ultimate fallback to default account
            exec ${lib.getExe wrappedPackages.${cfg.defaultAccount}} "$@"
            ;;
        esac
      '';

      # Create alias packages for each alias
      aliasPackages = lib.mapAttrsToList (aliasName: aliasFlags:
        let
          smartAlias = pkgs.writeShellScriptBin aliasName ''
            ${generateMatchFunction}

            account=$(_codex_match_account)

            case "$account" in
              ${lib.concatMapStringsSep "\n" ({ name, value }: ''
              "${name}")
                exec ${lib.getExe wrappedPackages.${name}} "$@" ${aliasFlags}
                ;;''
              ) sortedAccounts}
              *)
                exec ${lib.getExe wrappedPackages.${cfg.defaultAccount}} "$@" ${aliasFlags}
                ;;
            esac
          '';

          perAccountAliases = lib.mapAttrsToList (accountName: accountCfg:
            pkgs.writeShellScriptBin "${aliasName}-${accountName}" ''
              exec ${lib.getExe wrappedPackages.${accountName}} "$@" ${aliasFlags}
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
          message = "programs.multi-codex.defaultAccount must reference an existing account. Got '${cfg.defaultAccount}' but available accounts are: ${lib.concatStringsSep ", " accountNames}";
        }
        {
          assertion = accountNames != [ ];
          message = "programs.multi-codex requires at least one account to be defined";
        }
      ];

      # Create config directories and files for each account
      home.file = lib.foldlAttrs
        (acc: name: accountCfg:
          let
            configDir = getConfigDir name accountCfg;
            # Build config.toml: merge user settings with MCP servers
            configToml = accountCfg.settings // (
              lib.optionalAttrs (accountCfg.mcpServers != { }) {
                mcp_servers = accountCfg.mcpServers;
              }
            );
          in
          acc // {
            # config.toml
            "${configDir}/config.toml".source = tomlFormat.generate "codex-${name}-config.toml" configToml;

            # AGENTS.md
          } // lib.optionalAttrs (accountCfg.memory.text != null || accountCfg.memory.source != null) {
            "${configDir}/AGENTS.md" =
              if accountCfg.memory.text != null then { text = accountCfg.memory.text; }
              else { source = accountCfg.memory.source; };
          }

          # hooks.json
          // lib.optionalAttrs (accountCfg.hooksConfig != { }) {
            "${configDir}/hooks.json".text = builtins.toJSON accountCfg.hooksConfig;
          }

          # Symlink directories
          // lib.optionalAttrs (accountCfg.skillsDir != null) {
            "${configDir}/.agents/skills".source = accountCfg.skillsDir;
            "${configDir}/skills".source = accountCfg.skillsDir;
          }
          // lib.optionalAttrs (accountCfg.hooksDir != null) {
            "${configDir}/hooks".source = accountCfg.hooksDir;
          }

          # Inline hook scripts (executable)
          // lib.mapAttrs'
            (hookName: hookContent: {
              name = "${configDir}/hooks/${hookName}";
              value = {
                text = hookContent;
                executable = true;
              };
            })
            accountCfg.hooks

          # Inline skills (can be files or directories) — deploy to both paths
          # for codex <0.118.0 (.agents/skills/) and >=0.118.0 (skills/)
          // builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList
            (skillName: skillContent:
              let
                value = if lib.isPath skillContent then { source = skillContent; } else { text = skillContent; };
              in
              [
                { name = "${configDir}/.agents/skills/${skillName}"; inherit value; }
                { name = "${configDir}/skills/${skillName}"; inherit value; }
              ])
            accountCfg.skills))
        )
        { }
        enabledAccounts;

      # Shell integration: functions and prompt helper
      programs.zsh.initContent = lib.mkIf (config.programs.zsh.enable && (cfg.shellIntegration.functions || cfg.shellIntegration.showActive)) (
        let
          functionDefs = lib.optionalString cfg.shellIntegration.functions (
            lib.concatStringsSep "\n" (lib.mapAttrsToList
              (name: accountCfg: ''
                ${name}-codex() {
                  ${lib.getExe wrappedPackages.${name}} "$@"
                }
              '')
              enabledAccounts)
          );

          activeFunction = lib.optionalString cfg.shellIntegration.showActive ''
            ${generateMatchFunction}

            _codex_active_account() {
              local account=$(_codex_match_account)
              if [[ -n "$account" && "$account" != "${cfg.defaultAccount}" ]]; then
                echo "[$account]"
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
