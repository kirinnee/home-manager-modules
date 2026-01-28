# Home Manager Modules - Multi-Claude and Multi-GH

A collection of Home Manager modules for managing multiple accounts for CLI tools with automatic directory-based switching.

## Modules

### Multi-Claude (`multi-claude`)

Manage multiple Claude Code accounts with isolated configurations, MCP servers, and automatic directory-based account switching.

**Features:**
- Directory-based account switching
- Per-account configuration (settings.json, CLAUDE.md, rules, agents, commands, hooks, skills)
- MCP server support per account
- Shell integration with optional prompt helper
- Smart `claude` wrapper that routes to correct account
- **Custom aliases** for common flag combinations

### Multi-GH (`multi-gh`)

Manage multiple GitHub CLI accounts with automatic directory-based account switching via `gh auth switch`.

**Features:**
- Directory-based account switching
- Per-account binaries (`gh-personal`, `gh-work`, etc.)
- Smart `gh` wrapper that auto-switches accounts
- Shell integration with optional prompt helper
- Priority-based directory matching

## Quick Start

### Add as a Flake Input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-modules.url = "github:/kirinnee/home-manager-modules";
  };

  outputs = { self, nixpkgs, home-manager, home-manager-modules, ... }: {
    homeConfigurations."your-username" = home-manager.lib.homeManagerConfiguration {
      modules = [
        home-manager-modules.homeManagerModules.multi-claude
        home-manager-modules.homeManagerModules.multi-gh
        ./home.nix
      ];
    };
  };
}
```

## Multi-Claude Usage

### Basic Configuration

```nix
{ config, pkgs, ... }: {
  programs.multi-claude = {
    enable = true;
    defaultAccount = "personal";

    accounts = {
      personal = {
        directoryRules = [ "~/" ];
        settings = { };
      };

      work = {
        priority = 50;
        directoryRules = [ "~/Workspace/work" ];
        env = {
          ANTHROPIC_AUTH_TOKEN = "$WORK_CLAUDE_TOKEN";
        };
        mcpServers = {
          work-db = {
            transport = {
              type = "http";
              url = "http://localhost:8080/mcp";
            };
          };
        };
      };
    };
  };
}
```

### Key Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | boolean | `false` | Enable the module |
| `defaultPackage` | package | `pkgs.claude-code` | Default Claude Code package |
| `defaultAccount` | string | *(required)* | Fallback account name |
| `smartWrapper.enable` | boolean | `true` | Create smart `claude` wrapper |
| `shellIntegration.functions` | boolean | `false` | Create `<name>-claude` shell functions |
| `shellIntegration.showActive` | boolean | `true` | Add `_claude_active_account()` for prompts |
| `aliases` | attrs of string | `{ }` | Custom aliases (see below) |

### Aliases

Create short commands that automatically append flags:

```nix
programs.multi-claude = {
  enable = true;
  defaultAccount = "personal";

  aliases = {
    # Short alias for skipping permission prompts
    cc = "--dangerously-skip-permissions";

    # Alias for verbose output
    cv = "--verbose";

    # Alias for both flags combined
    ccv = "--dangerously-skip-permissions --verbose";
  };

  accounts = {
    personal = { directoryRules = [ "~/" ]; };
    work = { directoryRules = [ "~/Workspace/work" ]; };
  };
};
```

This generates the following commands:

- `cc` → `claude --dangerously-skip-permissions` (uses directory matching)
- `cc-personal` → `claude-personal --dangerously-skip-permissions` (direct to personal account)
- `cc-work` → `claude-work --dangerously-skip-permissions` (direct to work account)
- `cv`, `cv-personal`, `cv-work` → with `--verbose` flag

## Multi-GH Usage

### Basic Configuration

```nix
{ config, pkgs, ... }: {
  programs.multi-gh = {
    enable = true;
    defaultAccount = "personal";

    accounts = {
      personal = {
        username = "yourgithubusername";
        directoryRules = [ "~/" ];
      };

      work = {
        username = "workgithubusername";
        priority = 50;
        directoryRules = [ "~/src/work" ];
      };
    };
  };
}
```

### Key Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | boolean | `false` | Enable the module |
| `defaultPackage` | package | `pkgs.gh` | Default GitHub CLI package |
| `defaultAccount` | string | *(required)* | Fallback account name |
| `smartWrapper.enable` | boolean | `true` | Create smart `gh` wrapper |
| `shellIntegration.functions` | boolean | `false` | Create `gh-<name>` shell functions |
| `shellIntegration.showActive` | boolean | `true` | Add `_gh_active_account()` for prompts |
| `aliases` | attrs of string | `{ }` | Custom aliases (see below) |

### Aliases

Create short commands for common `gh` invocations:

```nix
programs.multi-gh = {
  enable = true;
  defaultAccount = "personal";

  aliases = {
    # Short alias for issue operations
    ghi = "issue";

    # Alias for PR operations with JSON output
    ghpr = "pr --json title,state,url";
  };

  accounts = {
    personal = {
      username = "yourgithubusername";
      directoryRules = [ "~/" ];
    };
    work = {
      username = "workgithubusername";
      directoryRules = [ "~/src/work" ];
    };
  };
};
```

This generates:
- `ghi` → `gh issue` (uses directory matching for account)
- `ghi-personal` → `gh-personal issue` (direct to personal account)
- `ghi-work` → `gh-work issue` (direct to work account)

### Per-Account Options (multi-gh)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | boolean | `true` | Enable this account |
| `priority` | int | `100` | Match priority (lower = first) |
| `username` | string | *(required)* | GitHub username for `gh auth switch` |
| `directoryRules` | list of string | `[ ]` | Paths that trigger this account (supports `~`) |
| `package` | package or null | `null` | Override package for this account |

## How It Works

When you run the wrapped command (`claude` or `gh`) in a directory:

1. The wrapper checks your current working directory against `directoryRules`
2. Rules are checked by **priority** (lower number = checked first)
3. First match wins, otherwise falls back to `defaultAccount`
4. The appropriate binary is executed with that account's config/credentials

## Shell Prompt Integration

Add to your zsh prompt to show the active account:

```nix
programs.zsh.promptInit = ''
  RPROMPT='$(_claude_active_account)$(_gh_active_account)'"$RPROMPT"
'';
```

This will show `[work]` in your prompt when in a work directory.

## Priority-Based Matching

More specific paths should have **lower priority** (checked first):

```nix
accounts = {
  general-work = {
    priority = 100;
    directoryRules = [ "~/src/work" ];
  };

  specific-project = {
    priority = 50;  # Checked BEFORE general-work
    directoryRules = [ "~/src/work/super-secret-project" ];
  };
};
```

## Generated Binaries

### Multi-Claude
For each account, a `claude-<name>` binary is created that:
- Sets `CLAUDE_CONFIG_DIR` to `~/.claude-<name>`
- Exports the account's `env` variables
- Passes `--mcp-config` if MCP servers are defined
- Executes the underlying `claude-code` binary

### Multi-GH
For each account, a `gh-<name>` binary is created that:
- Runs `gh auth switch -u <username>` before executing
- Executes the underlying `gh` binary with all arguments

## Requirements

- GitHub CLI users must run `gh auth login` for each account before using the module
- The module only handles account switching, not initial authentication

## File Structure (multi-claude)

For an account named `work`, the following structure is created:

```
~/.claude-work/
├── settings.json          # From account.settings
├── CLAUDE.md              # From account.memory.*
├── rules/                 # From account.rules* + account.rules
├── agents/                # From account.agents* + account.agents
├── commands/              # From account.commands* + account.commands
├── hooks/                 # From account.hooks* + account.hooks
└── skills/                # From account.skills* + account.skills
```
