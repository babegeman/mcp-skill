---
name: mcp-diagnostic
description: >
  Use this skill when the user asks to debug, inspect, diagnose, or review their MCP (Model Context Protocol)
  server configuration. Provides a comprehensive diagnostic report covering all configuration tiers
  (managed, user, project, local), server metadata (transport type, command, URL, environment),
  connection health, and a preview of the system prompt content that each MCP server contributes.
  Invoke via /mcp-diagnostic.
disable-model-invocation: true
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "[--full | --servers | --settings | --prompt-preview]"
---

# MCP Diagnostic Skill

You are an MCP diagnostic agent. Your job is to run the diagnostic collector script, interpret
its structured JSON output, and present a comprehensive, well-formatted diagnostic report to
the user.

## Step 1: Run the Diagnostic Collector

First, locate and execute the diagnostic script. It handles ALL mechanical work: config file
discovery, JSON parsing, server classification, secret redaction, health checks, and settings
auditing.

```bash
bash "$(find ~/.claude/skills/mcp-diagnostic/scripts .claude/skills/mcp-diagnostic/scripts -name 'mcp-diagnose.sh' 2>/dev/null | head -1)"
```

If the script is not found at either path, tell the user:
> The diagnostic script was not found. Make sure the skill is installed at
> `~/.claude/skills/mcp-diagnostic/` or `<project>/.claude/skills/mcp-diagnostic/`.

The script outputs a single JSON object. Capture the entire output.

## Step 2: Determine Scope from Arguments

- `$ARGUMENTS` is empty or `--full` → produce the FULL report (all sections)
- `$ARGUMENTS` is `--servers` → Sections 1-3 only (config tiers, server metadata, health)
- `$ARGUMENTS` is `--settings` → Section 4 only (settings & permissions)
- `$ARGUMENTS` is `--prompt-preview` → Section 5 only (system prompt preview)

## Step 3: Interpret the JSON and Produce the Report

Use the JSON output to produce the following sections. Do NOT re-read config files or re-run
checks — everything you need is in the JSON. Your value-add is formatting, analysis,
recommendations, and the system prompt preview (which requires your knowledge of MCP servers).

---

### Section 1: Configuration Tier Discovery

Using `config_files` from the JSON, produce this table:

```
| Tier | File Path | Exists? | Shared? | # Servers | Server Names |
|------|-----------|---------|---------|-----------|--------------|
```

Include ALL tiers, even those that don't exist (show "No" in Exists column).
After the table:
- If zero servers found anywhere, explain how to add one with `claude mcp add` examples
- Note which config files are git-trackable (shared) vs personal

---

### Section 2: Server Inventory & Metadata

Using `effective_servers` (winners after tier merging) and `all_servers_all_tiers` (every
definition including shadowed ones), produce a detailed card for each server:

```markdown
### Server: <name>
- **Defined in**: <tier> (`<source_file>`)
- **Transport**: stdio / http / sse
- **Health**: <healthy/warning/error> <emoji if appropriate>

#### Connection Details
For stdio:
- **Command**: `<command>`
- **Args**: `<args>`
- **Full command**: `<resolved_command>`
- **Package handler**: <npx/uvx/docker/bunx/node/python/deno/custom>
- **Package**: <detected package name>
- **Working directory**: <cwd or "default">
- **Runtime versions**: <node/python/etc version if detected>

For http/sse:
- **URL**: `<url>`
- **HTTP status**: <status code from health check>
- **Auth configured**: yes/no
- **Headers**: <redacted header list>

#### Environment Variables
<table of env vars — already redacted by the script>
<flag any ${VAR} references and whether they resolve, using env_var_refs>

#### Tier Inheritance
<if this server appears in conflicts[], explain which tiers define it and which wins>
```

---

### Section 3: Connection Health

Using `effective_servers` and their `health` and `issues` fields, produce:

1. A summary health table:

```
| Server | Transport | Health | Issues |
|--------|-----------|--------|--------|
```

2. For each server with issues, provide **specific troubleshooting steps**. Use your knowledge
   of common MCP problems:
   - Missing binary → suggest install command
   - Docker not running → suggest `docker desktop` or `systemctl start docker`
   - npx package not found → suggest `npm install -g <package>`
   - URL unreachable → suggest checking network, VPN, or URL typos
   - Auth required but no headers → suggest OAuth setup or API key configuration

3. Include the `environment.runtimes` data as a runtime availability reference table.

4. Include the `cli_mcp_list` output if it returned useful data (not a timeout message).

---

### Section 4: Settings & Permissions Audit

Using `settings_audit` from the JSON, produce a per-tier breakdown:

```markdown
### Settings: <tier> (`<path>`)

**Permissions:**
- Allow: <list or "none configured">
- Deny: <list or "none configured">
- MCP-specific rules: <any rules matching mcp/MCP patterns, or "none">

**MCP Server Policies:**
- Allowlist: <allowedMcpServers or "not configured">
- Denylist: <deniedMcpServers or "not configured">

**Environment Variables:**
<from settings env block, or "none">

**Hooks:**
<list each hook event and what it does, or "none configured">
<flag any hooks that could affect MCP behavior>
```

After all tiers, provide a **merged effective permissions** summary showing what the combined
effect of all tiers is.

---

### Section 5: System Prompt Preview

This is WHERE YOU ADD THE MOST VALUE. The script cannot do this part — it requires your
knowledge of MCP server packages and the Claude Code system prompt format.

For each server in `effective_servers`:

1. **Identify the MCP package** from the `package`, `command`, `args`, or `url` fields.

2. **If you recognize the package** (e.g., `@modelcontextprotocol/server-filesystem`,
   `@anthropic/mcp-server-github`, `mcp-server-sqlite`, Notion MCP, Slack MCP, etc.):
   - List the tools it provides with their names, descriptions, and parameter schemas
   - Format them as they would appear in the Claude system prompt:
   ```
   Tool: mcp__<server-name>__<tool-name>
   Description: <what it does>
   Parameters:
     - <param>: <type> (<required/optional>) — <description>
   ```
   - List any resources and prompts it exposes

3. **If you don't recognize the package**:
   - State that tool enumeration requires an active connection
   - Suggest the user run `/mcp` in an active Claude Code session to see live tools
   - If the package name gives clues (e.g., "database", "filesystem"), speculate on likely tools

4. **Estimate token impact**:
   - Each tool definition is roughly 100-300 tokens in the system prompt
   - Multiply by number of tools per server
   - Sum across all servers for total estimated MCP prompt overhead

End with:
```
### System Prompt Impact Summary
| Server | Est. Tools | Est. Tokens |
|--------|-----------|-------------|
| Total  | N         | ~N tokens   |
```

---

### Section 6: Final Summary & Recommendations

Produce a summary dashboard using `summary` from the JSON:

```
## MCP Diagnostic Summary

| Metric                | Value |
|-----------------------|-------|
| Config files found    | X of Y checked |
| Total servers         | N |
| Healthy               | N |
| Warnings              | N |
| Errors                | N |
| Conflicts             | N |
| Active settings tiers | <list> |
| Platform              | <platform> |
| Project root          | <path> |
```

Then provide **actionable recommendations** based on everything you found:
- Fix unhealthy servers (specific steps)
- Resolve conflicts between tiers
- Security suggestions (e.g., move secrets to env vars, use `.local.json` for personal config)
- Performance suggestions (e.g., too many MCP servers inflating system prompt)
- Missing best practices (e.g., no `.mcp.json` for team-shared servers)

---

## Important Rules

1. **NEVER re-read config files manually** — the script already did this. Use its JSON output.
2. **NEVER run `claude mcp list` yourself** — the script already tried and included the result.
3. **Secrets are pre-redacted** — the script handles this. Don't try to re-redact.
4. **Be specific** — exact paths, exact commands, exact server names.
5. **Be helpful** — don't just report problems, suggest fixes with copy-pasteable commands.
6. **Format for scanning** — use tables, headers, code blocks, and visual hierarchy.
7. **Acknowledge limitations** — if you can't enumerate tools (no active connection), say so clearly.
