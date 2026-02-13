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
/mcp-diagnostic              # Full diagnostic report
/mcp-diagnostic --servers     # Server inventory and health only
/mcp-diagnostic --settings    # Settings and permissions audit only
/mcp-diagnostic --prompt-preview  # MCP system prompt preview only
```

## What It Reports

### Configuration Tier Discovery
Scans all configuration files across every tier (managed, user, project, local) and reports which files exist, which define MCP servers, and where they live on disk.

### Server Inventory & Metadata
For every MCP server found, reports:
- Transport type (stdio, http, sse)
- Command, args, and package handler (npx, uvx, docker, etc.) for local servers
- URL and headers for remote servers
- Environment variables (secrets redacted)
- Inheritance and override information across tiers

### Settings & Permissions Audit
Extracts MCP-relevant settings from all tiers:
- Permission rules affecting MCP tools
- Allowlists and denylists (from managed settings)
- Environment variables from settings blocks
- Hooks that may affect MCP behavior

### Connection Health Check
Per-server diagnostics:
- Binary existence and executability for stdio servers
- Runtime version checks (node, python, etc.)
- Package manager availability (npx, uvx, docker)
- URL reachability for remote servers
- Specific troubleshooting steps for unhealthy servers

### Tool, Resource & Prompt Enumeration
Lists all capabilities exposed by each connected MCP server — tools, resources, and prompts with descriptions.

### Configuration Source Map
Consolidated view of tier merging: which server definitions win, which are shadowed, and any conflicts detected.

### System Prompt Preview
Approximates the content each MCP server contributes to Claude's system prompt, including tool definitions, resource listings, and estimated token counts.

## Configuration Tiers (Reference)

| Tier | Scope | Path | Shared? |
|------|-------|------|---------|
| Managed MCP | Organization | `/etc/claude-code/managed-mcp.json` (Linux) | Yes |
| Managed Settings | Organization | `/etc/claude-code/managed-settings.json` (Linux) | Yes |
| User | Personal (all projects) | `~/.claude.json` | No |
| Project | Team (git-tracked) | `<project>/.mcp.json` | Yes |
| Project Settings | Team settings | `<project>/.claude/settings.json` | Yes |
| Local Settings | Personal per-project | `<project>/.claude/settings.local.json` | No |
| User Settings | Personal global | `~/.claude/settings.json` | No |

## License

MIT
