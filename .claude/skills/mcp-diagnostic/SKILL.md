---
name: mcp-diagnostic
description: >
  Use this skill when the user asks to debug, inspect, diagnose, or review their MCP (Model Context Protocol)
  server configuration. Provides a comprehensive diagnostic report covering all configuration tiers
  (managed, user, project, local), server metadata (transport type, command, URL, environment),
  connection health, available tools/resources/prompts, and a preview of the system prompt content
  that each MCP server contributes. Invoke via /mcp-diagnostic.
disable-model-invocation: true
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, Task, WebFetch
argument-hint: "[--full | --servers | --settings | --prompt-preview]"
---

# MCP Diagnostic Skill

You are an MCP diagnostic agent. When invoked, you MUST produce a comprehensive, plaintext diagnostic
report of every MCP server configured in the user's environment. Follow every step below carefully.
Present all output in well-structured markdown with clear section headers.

## Arguments

- If `$ARGUMENTS` is empty or `--full`, run ALL sections below.
- If `$ARGUMENTS` is `--servers`, run only Sections 1-4.
- If `$ARGUMENTS` is `--settings`, run only Sections 5-6.
- If `$ARGUMENTS` is `--prompt-preview`, run only Section 7.

---

## Section 1: Configuration Tier Discovery

Identify and read every configuration source that can define MCP servers. Report which files
exist, which are missing, and which contain MCP server definitions. Present this as a table.

### Files to check (in precedence order, highest first):

| Tier | Scope | Path | Shared? |
|------|-------|------|---------|
| **Managed MCP** | Organization-wide (IT-deployed) | Linux: `/etc/claude-code/managed-mcp.json` | Yes |
| | | macOS: `/Library/Application Support/ClaudeCode/managed-mcp.json` | |
| | | Windows: `C:\Program Files\ClaudeCode\managed-mcp.json` | |
| **Managed Settings** | Organization-wide policies | Linux: `/etc/claude-code/managed-settings.json` | Yes |
| | | macOS: `/Library/Application Support/ClaudeCode/managed-settings.json` | |
| **User** | Personal (all projects) | `~/.claude.json` → `mcpServers` key | No |
| **Project** | Team-shared (git-tracked) | `<project-root>/.mcp.json` | Yes (via git) |
| **Local Settings** | Personal per-project | `<project-root>/.claude/settings.local.json` | No (gitignored) |
| **Project Settings** | Team project settings | `<project-root>/.claude/settings.json` | Yes (via git) |
| **User Settings** | Personal global settings | `~/.claude/settings.json` | No |

### Steps:

1. Determine the current working directory and project root (look for `.git` directory walking upward).
2. Detect the OS platform to know which managed paths to check.
3. For each file path above, check if the file exists.
4. If it exists, read it and extract any `mcpServers` configuration block.
5. Report the results in a table:

```
| Tier | File Path | Exists? | # Servers Defined | Server Names |
|------|-----------|---------|-------------------|--------------|
```

6. If no MCP servers are found anywhere, state that clearly and suggest how to add one
   (`claude mcp add` command examples).

---

## Section 2: Server Inventory & Metadata

For every MCP server discovered across all tiers, produce a detailed metadata card.

### For each server, report:

```
### Server: <name>
- **Defined in**: <tier name> (<file path>)
- **Transport**: stdio | http | sse
- **Status**: (will be filled in Section 4)

#### Connection Details:
  - For stdio servers:
    - **Command**: <command>
    - **Args**: <args list>
    - **Package handler**: <npx | uvx | docker | bunx | node | python | custom binary>
    - **Package**: <package name if detectable from args>
    - **Working directory**: <cwd if specified>
  - For http/sse servers:
    - **URL**: <url>
    - **Headers**: <list any configured headers, REDACT bearer tokens / API keys showing only first 4 and last 4 chars>

#### Environment Variables:
  - List all env vars configured for this server
  - REDACT sensitive values (API keys, tokens, passwords) — show only first 4 and last 4 characters
  - Flag any env vars that reference ${VAR} substitution and whether the var is currently set in the shell

#### Inheritance & Override Info:
  - Note if this server name appears in multiple tiers
  - Indicate which tier takes precedence (wins)
  - Flag any conflicts or shadowed definitions
```

---

## Section 3: Settings & Permissions Audit

Report all settings that affect MCP behavior, across all settings tiers.

### Steps:

1. Read each settings file that exists:
   - `~/.claude/settings.json` (user)
   - `<project-root>/.claude/settings.json` (project)
   - `<project-root>/.claude/settings.local.json` (local)
   - Managed settings path for current OS

2. Extract and report:
   - **Permission rules** that reference MCP-related tools (any `mcp_*` patterns, or MCP server tool names)
   - **Allowed/denied MCP servers** (from managed settings `allowedMcpServers` / `deniedMcpServers`)
   - **Environment variables** set via settings `env` blocks that might affect MCP servers
   - **Hooks** that reference MCP or could affect MCP behavior

3. Present as:

```
### Settings Tier: <tier name> (<file path>)

**Permissions affecting MCP:**
- allow: [list]
- deny: [list]

**MCP Allowlist/Denylist:**
- Allowed: [list or "not configured"]
- Denied: [list or "not configured"]

**Environment from settings:**
- KEY=VALUE (redacted if sensitive)

**Relevant Hooks:**
- <event>: <hook description>
```

---

## Section 4: Connection Health Check

Run the built-in MCP status check and augment it with additional diagnostics.

### Steps:

1. Run `claude mcp list` to get the current MCP server list from the CLI's perspective.
2. For each **stdio** server:
   - Check if the command binary exists and is executable (`which <command>` or `command -v`).
   - If it uses `npx`, check if the package is installed or will be fetched (`npx --yes` behavior).
   - If it uses `uvx`, check if `uvx` is available.
   - If it uses `docker`, check if docker is running and the image exists locally.
   - If it uses `node` or `python`, check the runtime version.
   - Report the full resolved command that would be executed.
3. For each **http/sse** server:
   - Attempt a basic connectivity check if possible (report URL reachability).
   - Note if OAuth or API key authentication is required.
4. Report a per-server health summary:

```
| Server | Transport | Binary/URL OK? | Auth Configured? | Overall Health |
|--------|-----------|----------------|------------------|----------------|
| name   | stdio     | Yes/No         | N/A              | Healthy / Warning / Error |
```

5. For any unhealthy servers, provide specific troubleshooting steps.

---

## Section 5: Tool, Resource & Prompt Enumeration

For each connected and healthy MCP server, enumerate all capabilities it exposes.

### Steps:

1. Run `claude mcp list-tools` (if available) or note that tool enumeration requires an active session.
2. For each server, list:

```
### Server: <name>

**Tools (<count>):**
| Tool Name | Description (first 80 chars) |
|-----------|------------------------------|

**Resources (<count>):**
| Resource URI | Name | Description |
|-------------|------|-------------|

**Prompts (<count>):**
| Prompt Name | Description | Arguments |
|-------------|-------------|-----------|
```

3. If tool enumeration is not possible outside an active MCP connection, explain this and
   suggest the user run `/mcp` within an active Claude Code session instead.

---

## Section 6: Configuration Source Map

Produce a consolidated view showing exactly where every piece of MCP-related configuration
originates and how the tiers merge.

### Output format:

```
## Configuration Source Map

### Effective MCP Server List (after tier merging):

| # | Server Name | Winning Tier | Defined In | Shadowed By |
|---|-------------|-------------|------------|-------------|
| 1 | github      | Project     | .mcp.json  | —           |
| 2 | database    | User        | ~/.claude.json | —       |

### Tier Merge Details:
- Managed tier defines: [list or none]
- User tier defines: [list or none]
- Project tier defines: [list or none]
- Local tier defines: [list or none]

### Conflicts Detected:
- <server name> defined in both <tier A> and <tier B>; <tier> wins because <reason>
  (or "No conflicts detected")
```

---

## Section 7: System Prompt Preview

Generate a preview of what the MCP-contributed system prompt content would look like for the
current configuration. This is the content that gets injected into Claude's context when MCP
servers are connected.

### Steps:

1. For each configured server, construct a preview block showing:

```
## MCP System Prompt Preview

> Note: This is an approximation of what Claude Code injects into the system prompt
> for each connected MCP server. The actual prompt is generated at runtime when
> servers connect and may vary slightly.

---

### Server: <name> (<transport>)

#### Tools contributed to system prompt:

For each tool, the system prompt would include something like:

\`\`\`
<tool>
  <name>mcp__<server-name>__<tool-name></name>
  <description><tool description></description>
  <parameters>
    <parameter name="param1" type="string" required="true">
      Description of param1
    </parameter>
    ...
  </parameters>
</tool>
\`\`\`

#### Resources contributed:
(list resource definitions that would be available)

#### Prompts contributed:
(list prompt templates that would be available)

---
```

2. If tool details are not available (servers not currently connected), construct the preview
   based on the server's known package/type and document what WOULD appear. For well-known
   MCP servers (filesystem, GitHub, Slack, Notion, etc.), provide example tool listings based
   on common knowledge of those packages.

3. Show an estimated token count for the MCP system prompt contribution if possible.

4. End with a summary:

```
### MCP System Prompt Summary
- Total servers: <N>
- Estimated tools: <N> (from connected servers) + <N> (from unconnected servers, unknown)
- Estimated system prompt addition: ~<N> tokens (approximate)
```

---

## Final Summary

End the diagnostic report with:

```
## MCP Diagnostic Summary

| Metric | Value |
|--------|-------|
| Config files found | X of Y checked |
| Total servers defined | N |
| Healthy servers | N |
| Warning servers | N |
| Unhealthy servers | N |
| Total tools available | N (or "requires active connection") |
| Configuration conflicts | N |
| Settings tiers active | list |

### Recommendations:
1. (Any actionable recommendations based on findings)
2. (Suggestions for fixing unhealthy servers)
3. (Notes about missing configurations or best practices)
```

---

## Important Notes

- **REDACT SECRETS**: Always redact API keys, tokens, passwords, and other sensitive values.
  Show only the first 4 and last 4 characters with asterisks in between (e.g., `sk-1****xyz9`).
  If a value is 8 characters or fewer, show only `****REDACTED****`.
- **Be thorough**: Check every file path. Don't skip a tier just because it's unlikely to exist.
- **Be precise**: Report exact file paths, exact server names, exact commands.
- **Be helpful**: When something is wrong, don't just report it — suggest how to fix it.
- **Format clearly**: Use tables, code blocks, and headers for scannable output.
