# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A flake-based collection of Home Manager modules that provide multi-account management for CLI tools (Claude Code, GitHub CLI, Google Workspace CLI, Codex CLI, Gemini CLI, OpenCode) with automatic directory-based account switching.

## Build & Validation

```bash
nix flake check                          # Validate flake syntax and outputs
direnv exec . nix flake check            # Same, but with direnv if .envrc exists
```

There is no test suite. Validation is done via `nix flake check`.

## Formatting

```bash
nixpkgs-fmt modules/*.nix                # Format Nix files
```

The dev shell (via `flake.nix`) provides `nixpkgs-fmt` and `nil` (Nix LSP).

## Architecture

### Module Structure

Each module in `modules/` follows the same pattern:

1. **Priority-sorted directory matching** — shell functions (`_<tool>_match_account`) check `$PWD` against `directoryRules`, ordered by `priority` (lower = checked first). First match wins; falls back to `defaultAccount`.
2. **Per-account binaries** — `writeShellScriptBin` creates `<tool>-<name>` wrappers that set account-specific env vars / config dirs before `exec`-ing the real binary.
3. **Smart wrapper** — a single `<tool>` binary that calls the match function, then delegates to the correct per-account binary.
4. **Aliases** — optional short commands (`cc`, `ghi`, `gd`) that append flags and generate both directory-matched and account-pinned variants.
5. **Shell integration** — optional prompt helpers (`_<tool>_active_account`) and convenience functions.

### Option Namespaces

| Module file | Option path | Config format | Isolation env var |
|---|---|---|---|
| `multi-claude.nix` | `programs.claude-multi` | JSON | `CLAUDE_CONFIG_DIR` |
| `multi-gh.nix` | `programs.multi-gh` | — | `gh auth switch` |
| `multi-gws.nix` | `programs.multi-gws` | — | `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` |
| `multi-codex.nix` | `programs.multi-codex` | TOML | `CODEX_HOME` |
| `multi-gemini.nix` | `programs.multi-gemini` | JSON | `GEMINI_CLI_HOME` |
| `multi-opencode.nix` | `programs.multi-opencode` | JSON | `OPENCODE_CONFIG` |

### Shared Patterns (duplicated across modules, not DRY-extracted)

- `expandHome` — expands `~` prefix using `config.home.homeDirectory`
- `sortedAccounts` — `lib.sort` on priority, filtered to enabled accounts
- `generateMatchFunction` — identical structure across all three modules
- Account submodule options: `enable`, `priority`, `directoryRules`, `package`, `env`

### Module-Specific Details

- **multi-claude**: Most complex. Manages full Claude Code config tree (settings.json, CLAUDE.md, rules/, agents/, commands/, hooks/, skills/) and MCP server config via `--mcp-config`. Uses `pkgs.formats.json` for generating MCP config files.
- **multi-gh**: Runs `gh auth switch -u <username>` before each invocation. Match function returns username, not account name.
- **multi-gws**: Sets `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` per account. Receives `gwsPackage` as a flake input argument (injected in `flake.nix`).
- **multi-codex**: Generates `config.toml` (TOML format) per account. MCP servers go into `[mcp_servers]` section. Hooks use separate `hooks.json` file. Skills placed in `.agents/skills/`. Memory file is `AGENTS.md`.
- **multi-gemini**: Generates `settings.json` per account. Hooks and MCP servers merge into settings.json. Skills in `skills/`, commands in `commands/` (TOML), policies in `policies/` (TOML). Memory via `memory.md`, context via `GEMINI.md`.
- **multi-opencode**: Generates `opencode.json` per account. MCP servers go under `mcp` key (not `mcpServers`). Plugins replace hooks (TS/JS files in `plugins/`). Supports custom tools (`tools/`). Memory via `AGENTS.md`. Config dir is `~/.config/opencode-<name>/`.

### Flake Outputs

- `homeManagerModules.multi-claude` / `multi-gh` / `multi-gws` / `multi-codex` / `multi-gemini` / `multi-opencode` — the six modules
- `devShells.<system>.default` — provides `nixpkgs-fmt` and `nil`
- `multi-gws` module receives its package from the `gws` flake input (not from nixpkgs)
