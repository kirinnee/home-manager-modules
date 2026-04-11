{ config, lib, pkgs, ... }:

let
  cfg = config.programs.multi-gemini;

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
    then ".gemini-${accountCfg.configDirName}"
    else ".gemini-${name}";

  # Create a wrapped gemini binary for an account
  createWrappedGemini = name: accountCfg:
    let
      basePackage = if accountCfg.package != null then accountCfg.package else cfg.defaultPackage;
      geminiBinary = lib.getExe basePackage;
      configDir = getConfigDir name accountCfg;
      envExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "export ${k}=${v}") accountCfg.env
      );
    in
    pkgs.writeShellScriptBin "gemini-${name}" ''
      export GEMINI_CLI_HOME="$HOME/${configDir}"
      ${envExports}
      exec ${geminiBinary} "$@"
    '';

  # Generate the directory matching shell function (single source of truth)
  generateMatchFunction = ''
    _gemini_match_account() {
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
  options.programs.multi-gemini = {
    enable = lib.mkEnableOption "Gemini CLI Multi-Account manager";

    defaultPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.gemini-cli;
      description = "Default Gemini CLI package to use";
    };

    defaultAccount = lib.mkOption {
      type = lib.types.str;
      description = "Default account when CWD doesn't match any rules (must exist in accounts)";
    };

    smartWrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create smart `gemini` wrapper that auto-detects account";
      };
    };

    shellIntegration = {
      functions = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create `<name>-gemini` shell functions for each account";
      };

      showActive = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add `_gemini_active_account()` function for shell prompts";
      };
    };

    aliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''Alias definitions. Each alias creates a short command that appends arguments to gemini. For example, `gm = "-m flash"` creates `gm`, `gm-personal`, `gm-work`, etc.'';
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
            description = "Override the config directory name. Defaults to account name. Config will be at ~/.gemini-<configDirName>";
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
            description = "Gemini CLI settings.json content (model, theme, sandbox, etc.)";
          };

          mcpServers = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "MCP server configurations (merged into settings.json under mcpServers)";
          };

          hooks = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "Hooks configuration (merged into settings.json under hooks key)";
          };

          memory = {
            text = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Inline memory.md content";
            };

            source = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "memory.md file path to copy";
            };
          };

          context = {
            text = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Inline GEMINI.md content (global context instructions)";
            };

            source = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "GEMINI.md file path to copy";
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
            description = "Inline command files (attrset of filename => content). TOML format. Extension is preserved as-is.";
          };

          commandsDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of command files to symlink into commands/";
          };

          agents = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Inline agent files (attrset of filename => content). Extension is preserved as-is.";
          };

          agentsDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of agent files to symlink into agents/";
          };

          policies = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Inline policy files (attrset of filename => content). TOML format.";
          };

          policiesDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of policy files to symlink into policies/";
          };

          hooksDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Directory of hook scripts to symlink (for hooks that reference external commands)";
          };

          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Environment variables to export before running gemini binary. Supports shell expansion.";
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
      wrappedPackages = lib.mapAttrs createWrappedGemini enabledAccounts;

      # Generate the smart wrapper script
      smartWrapperScript = pkgs.writeShellScriptBin "gemini" ''
        # Gemini Multi-Account Smart Wrapper
        # Automatically switches accounts based on current working directory

        ${generateMatchFunction}

        # Main execution
        account=$(_gemini_match_account)

        # Show which account is being used
        if [[ -n "$account" ]]; then
          echo "Using Gemini account: $account" >&2
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

            account=$(_gemini_match_account)

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
          message = "programs.multi-gemini.defaultAccount must reference an existing account. Got '${cfg.defaultAccount}' but available accounts are: ${lib.concatStringsSep ", " accountNames}";
        }
        {
          assertion = accountNames != [ ];
          message = "programs.multi-gemini requires at least one account to be defined";
        }
      ];

      # Create config directories and files for each account
      home.file = lib.foldlAttrs
        (acc: name: accountCfg:
          let
            configDir = getConfigDir name accountCfg;
            # Build settings.json: merge user settings with hooks and MCP servers
            settingsJson = accountCfg.settings // (
              lib.optionalAttrs (accountCfg.hooks != { }) {
                hooks = accountCfg.hooks;
              }
            ) // (
              lib.optionalAttrs (accountCfg.mcpServers != { }) {
                mcpServers = accountCfg.mcpServers;
              }
            );
          in
          acc // {
            # settings.json
            "${configDir}/settings.json".text = builtins.toJSON settingsJson;

            # memory.md
          } // lib.optionalAttrs (accountCfg.memory.text != null || accountCfg.memory.source != null) {
            "${configDir}/memory.md" =
              if accountCfg.memory.text != null then { text = accountCfg.memory.text; }
              else { source = accountCfg.memory.source; };
          }

          # GEMINI.md
          // lib.optionalAttrs (accountCfg.context.text != null || accountCfg.context.source != null) {
            "${configDir}/GEMINI.md" =
              if accountCfg.context.text != null then { text = accountCfg.context.text; }
              else { source = accountCfg.context.source; };
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
          // lib.optionalAttrs (accountCfg.policiesDir != null) {
            "${configDir}/policies".source = accountCfg.policiesDir;
          }
          // lib.optionalAttrs (accountCfg.hooksDir != null) {
            "${configDir}/hooks".source = accountCfg.hooksDir;
          }

          # Inline commands (TOML format)
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

          # Inline policies (TOML format)
          // lib.mapAttrs'
            (policyName: policyContent: {
              name = "${configDir}/policies/${policyName}";
              value.text = policyContent;
            })
            accountCfg.policies

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
                ${name}-gemini() {
                  ${lib.getExe wrappedPackages.${name}} "$@"
                }
              '')
              enabledAccounts)
          );

          activeFunction = lib.optionalString cfg.shellIntegration.showActive ''
            ${generateMatchFunction}

            _gemini_active_account() {
              local account=$(_gemini_match_account)
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
