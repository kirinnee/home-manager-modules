{ config, lib, pkgs, ... }:

let
  cfg = config.programs.multi-opencode;

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
    then "opencode-${accountCfg.configDirName}"
    else "opencode-${name}";

  # Create a wrapped opencode binary for an account
  createWrappedOpencode = name: accountCfg:
    let
      basePackage = if accountCfg.package != null then accountCfg.package else cfg.defaultPackage;
      opencodeBinary = lib.getExe basePackage;
      configDirName = getConfigDir name accountCfg;
      configFile = "${config.home.homeDirectory}/.config/${configDirName}/opencode.json";
      envExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "export ${k}=${v}") accountCfg.env
      );
    in
    pkgs.writeShellScriptBin "opencode-${name}" ''
      export OPENCODE_CONFIG="${configFile}"
      ${envExports}
      exec ${opencodeBinary} "$@"
    '';

  # Generate the directory matching shell function (single source of truth)
  generateMatchFunction = ''
    _opencode_match_account() {
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
  options.programs.multi-opencode = {
    enable = lib.mkEnableOption "OpenCode Multi-Account manager";

    defaultPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.opencode;
      description = "Default OpenCode package to use";
    };

    defaultAccount = lib.mkOption {
      type = lib.types.str;
      description = "Default account when CWD doesn't match any rules (must exist in accounts)";
    };

    smartWrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create smart `opencode` wrapper that auto-detects account";
      };
    };

    shellIntegration = {
      functions = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create `<name>-opencode` shell functions for each account";
      };

      showActive = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add `_opencode_active_account()` function for shell prompts";
      };
    };

    aliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''Alias definitions. Each alias creates a short command that appends arguments to opencode. For example, `oc = "--prompt"` creates `oc`, `oc-personal`, `oc-work`, etc.'';
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
            description = "Override the config directory name. Defaults to account name. Config will be at ~/.config/opencode-<configDirName>";
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
            description = "OpenCode opencode.json content (model, provider, compaction, etc.)";
          };

          mcpServers = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "MCP server configurations (merged into opencode.json under mcp key)";
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
            description = "Inline skill files/directories (attrset of path => content or dir). Placed in skills/";
          };

          skillsDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of skill files to symlink into skills/";
          };

          commands = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Inline command files (attrset of filename => content). Markdown format.";
          };

          commandsDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of command files to symlink into commands/";
          };

          agents = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Inline agent definition files (attrset of filename => content). Markdown format.";
          };

          agentsDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of agent files to symlink into agents/";
          };

          tools = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Inline custom tool files (attrset of filename => TypeScript content)";
          };

          toolsDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of custom tool files to symlink into tools/";
          };

          plugins = lib.mkOption {
            type = lib.types.listOf (lib.types.either lib.types.str (lib.types.listOf lib.types.anything));
            default = [ ];
            description = "Plugin names or [name, opts] tuples (merged into opencode.json under plugin key)";
          };

          pluginsDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of plugin files (TS/JS) to symlink into plugins/";
          };

          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Environment variables to export before running opencode binary. Supports shell expansion.";
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
      wrappedPackages = lib.mapAttrs createWrappedOpencode enabledAccounts;

      # Generate the smart wrapper script
      smartWrapperScript = pkgs.writeShellScriptBin "opencode" ''
        # OpenCode Multi-Account Smart Wrapper
        # Automatically switches accounts based on current working directory

        ${generateMatchFunction}

        # Main execution
        account=$(_opencode_match_account)

        # Show which account is being used
        if [[ -n "$account" ]]; then
          echo "Using OpenCode account: $account" >&2
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

            account=$(_opencode_match_account)

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
          message = "programs.multi-opencode.defaultAccount must reference an existing account. Got '${cfg.defaultAccount}' but available accounts are: ${lib.concatStringsSep ", " accountNames}";
        }
        {
          assertion = accountNames != [ ];
          message = "programs.multi-opencode requires at least one account to be defined";
        }
      ];

      # Create config directories and files for each account
      home.file = lib.foldlAttrs
        (acc: name: accountCfg:
          let
            configDirName = getConfigDir name accountCfg;
            configDir = ".config/${configDirName}";
            # Build opencode.json: merge user settings with MCP, plugins
            configJson = accountCfg.settings // (
              lib.optionalAttrs (accountCfg.mcpServers != { }) {
                mcp = accountCfg.mcpServers;
              }
            ) // (
              lib.optionalAttrs (accountCfg.plugins != [ ]) {
                plugin = accountCfg.plugins;
              }
            );
          in
          acc // {
            # opencode.json
            "${configDir}/opencode.json".text = builtins.toJSON configJson;

            # AGENTS.md
          } // lib.optionalAttrs (accountCfg.memory.text != null || accountCfg.memory.source != null) {
            "${configDir}/AGENTS.md" =
              if accountCfg.memory.text != null then { text = accountCfg.memory.text; }
              else { source = accountCfg.memory.source; };
          }

          # Symlink directories
          // lib.optionalAttrs (accountCfg.skillsDir != null) {
            "${configDir}/skills".source = accountCfg.skillsDir;
          }
          // lib.optionalAttrs (accountCfg.commandsDir != null) {
            "${configDir}/commands".source = accountCfg.commandsDir;
          }
          // lib.optionalAttrs (accountCfg.agentsDir != null) {
            "${configDir}/agents".source = accountCfg.agentsDir;
          }
          // lib.optionalAttrs (accountCfg.toolsDir != null) {
            "${configDir}/tools".source = accountCfg.toolsDir;
          }
          // lib.optionalAttrs (accountCfg.pluginsDir != null) {
            "${configDir}/plugins".source = accountCfg.pluginsDir;
          }

          # Inline commands (Markdown format)
          // lib.mapAttrs'
            (cmdName: cmdContent: {
              name = "${configDir}/commands/${cmdName}";
              value.text = cmdContent;
            })
            accountCfg.commands

          # Inline agents
          // lib.mapAttrs'
            (agentName: agentContent: {
              name = "${configDir}/agents/${agentName}";
              value.text = agentContent;
            })
            accountCfg.agents

          # Inline tools (TypeScript)
          // lib.mapAttrs'
            (toolName: toolContent: {
              name = "${configDir}/tools/${toolName}";
              value.text = toolContent;
            })
            accountCfg.tools

          # Inline skills (can be files or directories)
          // lib.mapAttrs'
            (skillName: skillContent:
              if lib.isPath skillContent then
                { name = "${configDir}/skills/${skillName}"; value.source = skillContent; }
              else
                { name = "${configDir}/skills/${skillName}"; value.text = skillContent; }
            )
            accountCfg.skills
        )
        { }
        enabledAccounts;

      # Shell integration: functions and prompt helper
      programs.zsh.initContent = lib.mkIf (config.programs.zsh.enable && (cfg.shellIntegration.functions || cfg.shellIntegration.showActive)) (
        let
          functionDefs = lib.optionalString cfg.shellIntegration.functions (
            lib.concatStringsSep "\n" (lib.mapAttrsToList
              (name: accountCfg: ''
                ${name}-opencode() {
                  ${lib.getExe wrappedPackages.${name}} "$@"
                }
              '')
              enabledAccounts)
          );

          activeFunction = lib.optionalString cfg.shellIntegration.showActive ''
            ${generateMatchFunction}

            _opencode_active_account() {
              local account=$(_opencode_match_account)
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
