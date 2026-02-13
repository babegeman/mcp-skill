# mcp-diagnostic

A Claude Code skill that provides comprehensive diagnostic reporting for MCP (Model Context Protocol) server configurations. Surfaces configuration tiers, server metadata, connection health, and system prompt previews — all in one command.

## Installation

Copy the `.claude/skills/mcp-diagnostic/` directory into your project or user-level Claude Code skills folder:

```bash
# Project-level (shared with team via git)
cp -r .claude/skills/mcp-diagnostic <your-project>/.claude/skills/

# User-level (available in all your projects)
cp -r .claude/skills/mcp-diagnostic ~/.claude/skills/
```

## Usage

Inside a Claude Code session:

```
/mcp-diagnostic                   # Full diagnostic report
/mcp-diagnostic --servers         # Server inventory and health only
/mcp-diagnostic --settings        # Settings and permissions audit only
/mcp-diagnostic --prompt-preview  # MCP system prompt preview only
```

### Fixing Authentication Issues

When the diagnostic detects authentication problems (401/403 errors):

- **OAuth-based servers (Atlassian)**: Run `claude mcp` in your terminal to re-authenticate
- **Token-based servers (GitHub)**: Regenerate your token and update the config file manually
- OAuth credentials are managed securely by the Claude CLI, not stored in config files

## Architecture

The skill uses a two-layer design:

### Layer 1: Shell Script (`scripts/mcp-diagnose.sh`)

A bash script that handles all **mechanical, deterministic** work:

- Discovers config files across all tiers (managed, user, project, local)
- Parses JSON with `jq` to extract MCP server definitions
- Classifies each server (transport type, package handler, env vars)
- Redacts sensitive values (API keys, tokens, passwords)
- Health-checks each server (binary existence, runtime versions, URL reachability)
- Audits settings files for MCP-relevant permissions, hooks, and policies
- Outputs a single structured JSON object

### Layer 2: SKILL.md (Claude's Instructions)

The prompt tells Claude to:

1. **Run the script** — one Bash call collects everything
2. **Interpret the JSON** — format it into a readable diagnostic report
3. **Add analysis** — troubleshooting steps, recommendations, best practices
4. **Generate system prompt previews** — uses Claude's knowledge of MCP server packages to show what tools each server contributes to the system prompt

This separation means the script is fast (no LLM calls for data collection) and Claude focuses on what it's good at (synthesis, explanation, recommendations).

## What It Reports

### Configuration Tier Discovery
Scans all configuration files across every tier and reports which exist, which define MCP servers, and where they live on disk.

| Tier | Scope | Path | Shared? |
|------|-------|------|---------|
| Managed MCP | Organization | `/etc/claude-code/managed-mcp.json` (Linux) | Yes |
| Managed Settings | Organization | `/etc/claude-code/managed-settings.json` (Linux) | Yes |
| User | Personal (all projects) | `~/.claude.json` | No |
| Project | Team (git-tracked) | `<project>/.mcp.json` | Yes |
| Project Settings | Team settings | `<project>/.claude/settings.json` | Yes |
| Local Settings | Personal per-project | `<project>/.claude/settings.local.json` | No |
| User Settings | Personal global | `~/.claude/settings.json` | No |

### Server Inventory & Metadata
Per-server detail cards including:
- Transport type (stdio, http, sse)
- Command, args, and package handler (npx, uvx, docker, bunx, node, python, deno, custom)
- URL and headers for remote servers
- Environment variables (auto-redacted)
- `${VAR}` reference resolution status
- Tier inheritance and conflict detection

### Connection Health
- Binary existence and executability checks for stdio servers
- Runtime version detection (Node.js, Python, uv, Docker)
- **MCP protocol handshake testing** for HTTP/SSE servers (sends proper `initialize` JSON-RPC message)
- HTTP status code validation and MCP response verification
- **OAuth server detection** - Automatically detects OAuth-based servers (like Atlassian) and marks them as healthy even with 401 status, since OAuth credentials are managed by Claude CLI
- Authentication header validation
- Specific troubleshooting steps for each issue found

### Settings & Permissions Audit
- Permission allow/deny rules affecting MCP tools
- Managed MCP allowlists and denylists
- Environment variables from settings tiers
- Hooks that may affect MCP behavior
- Merged effective permissions across all tiers

### System Prompt Preview
- Tool definitions as they appear in Claude's context (`mcp__<server>__<tool>`)
- Resource and prompt listings
- Estimated token impact per server
- Recognizes common MCP packages and lists their known tools

## Requirements

- `jq` (for JSON parsing in the diagnostic script)
- `bash` 4+
- `curl` (for HTTP health checks on remote servers)

## License

MIT License - see [LICENSE](LICENSE) for details.

Feel free to use, modify, and distribute this skill. Contributions welcome!
