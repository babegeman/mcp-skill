#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# mcp-diagnose.sh — MCP Server Diagnostic Collector
#
# Discovers, parses, and health-checks all MCP server configurations
# across every Claude Code configuration tier. Outputs structured JSON
# for Claude to interpret, format, and augment with recommendations.
#
# Usage: bash mcp-diagnose.sh [--section <name>] [--project-dir <path>]
#   Sections: all (default), configs, servers, health, settings
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Argument parsing ────────────────────────────────────────────────
SECTION="all"
PROJECT_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --section)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo '{"error":"--section requires a value (all, configs, servers, health, settings)"}' >&2
        exit 1
      fi
      SECTION="$2"
      shift 2
      ;;
    --project-dir)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo '{"error":"--project-dir requires a path value"}' >&2
        exit 1
      fi
      PROJECT_DIR="$2"
      shift 2
      ;;
    -*)
      echo "{\"error\":\"Unknown option: $1. Usage: bash mcp-diagnose.sh [--section <name>] [--project-dir <path>]\"}" >&2
      exit 1
      ;;
    *)
      # Legacy positional arg support: first arg is section, second is project-dir
      if [[ "$SECTION" == "all" ]]; then
        SECTION="$1"
      else
        PROJECT_DIR="$1"
      fi
      shift
      ;;
  esac
done

# ── Preflight: verify dependencies ──────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo '{"error":"jq is required but not installed. Install with: apt-get install jq / brew install jq"}' >&2
  exit 1
fi

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo '{"error":"bash 4+ is required. Current version: '"${BASH_VERSION}"'"}' >&2
  exit 1
fi

HAS_CURL=true
if ! command -v curl &>/dev/null; then
  HAS_CURL=false
fi

# ── Platform detection ──────────────────────────────────────────────
detect_platform() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "darwin" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)       echo "unknown" ;;
  esac
}

PLATFORM="$(detect_platform)"

# ── Find project root (walk up looking for .git) ───────────────────
find_project_root() {
  local dir="$PROJECT_DIR"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.git" ]]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done
  echo "$PROJECT_DIR"
}

PROJECT_ROOT="$(find_project_root)"

# ── Secret redaction ────────────────────────────────────────────────
redact() {
  local val="$1"
  local len=${#val}
  if [[ $len -le 8 ]]; then
    echo "****REDACTED****"
  else
    echo "${val:0:4}****${val:$((len-4)):4}"
  fi
}

is_sensitive_key() {
  local key="$1"
  local lower_key
  lower_key="$(echo "$key" | tr '[:upper:]' '[:lower:]')"
  case "$lower_key" in
    *key*|*token*|*secret*|*password*|*credential*|*auth*|*bearer*|*api_key*|*apikey*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# ── Redact values in a JSON object, returns new JSON ────────────────
redact_json_object() {
  local json="$1"
  echo "$json" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null | while IFS=$'\t' read -r key val; do
    if is_sensitive_key "$key"; then
      local redacted
      redacted="$(redact "$val")"
      echo "$key"$'\t'"$redacted"
    else
      echo "$key"$'\t'"$val"
    fi
  done | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}'
}

# ── Build config file paths for current platform ───────────────────
get_config_paths() {
  local managed_mcp managed_settings
  case "$PLATFORM" in
    darwin)
      managed_mcp="/Library/Application Support/ClaudeCode/managed-mcp.json"
      managed_settings="/Library/Application Support/ClaudeCode/managed-settings.json"
      ;;
    linux)
      managed_mcp="/etc/claude-code/managed-mcp.json"
      managed_settings="/etc/claude-code/managed-settings.json"
      ;;
    windows)
      managed_mcp="C:\\Program Files\\ClaudeCode\\managed-mcp.json"
      managed_settings="C:\\Program Files\\ClaudeCode\\managed-settings.json"
      ;;
    *)
      managed_mcp="/etc/claude-code/managed-mcp.json"
      managed_settings="/etc/claude-code/managed-settings.json"
      ;;
  esac

  jq -n \
    --arg managed_mcp "$managed_mcp" \
    --arg managed_settings "$managed_settings" \
    --arg user_mcp "$HOME/.claude.json" \
    --arg project_mcp "$PROJECT_ROOT/.mcp.json" \
    --arg user_settings "$HOME/.claude/settings.json" \
    --arg project_settings "$PROJECT_ROOT/.claude/settings.json" \
    --arg local_settings "$PROJECT_ROOT/.claude/settings.local.json" \
    '[
      { "tier": "managed-mcp",      "scope": "organization", "shared": true,  "path": $managed_mcp,      "type": "mcp" },
      { "tier": "managed-settings", "scope": "organization", "shared": true,  "path": $managed_settings, "type": "settings" },
      { "tier": "user",             "scope": "all-projects", "shared": false, "path": $user_mcp,         "type": "mcp" },
      { "tier": "project",          "scope": "project",      "shared": true,  "path": $project_mcp,      "type": "mcp" },
      { "tier": "user-settings",    "scope": "all-projects", "shared": false, "path": $user_settings,    "type": "settings" },
      { "tier": "project-settings", "scope": "project",      "shared": true,  "path": $project_settings, "type": "settings" },
      { "tier": "local-settings",   "scope": "project",      "shared": false, "path": $local_settings,   "type": "settings" }
    ]'
}

# ── Read and parse a config file ────────────────────────────────────
read_config_file() {
  local path="$1"
  local tier="$2"
  local cfg_type="$3"

  if [[ ! -f "$path" ]]; then
    jq -n --arg path "$path" --arg tier "$tier" --arg type "$cfg_type" \
      '{ path: $path, tier: $tier, type: $type, exists: false, servers: {}, settings: {} }'
    return
  fi

  local content
  content="$(cat "$path" 2>/dev/null)" || content="{}"

  # Validate JSON
  if ! echo "$content" | jq empty 2>/dev/null; then
    jq -n --arg path "$path" --arg tier "$tier" --arg type "$cfg_type" \
      '{ path: $path, tier: $tier, type: $type, exists: true, parse_error: "Invalid JSON", servers: {}, settings: {} }'
    return
  fi

  local servers="{}"
  local settings="{}"

  # Extract mcpServers
  servers="$(echo "$content" | jq '.mcpServers // {}' 2>/dev/null)" || servers="{}"

  # For settings files, extract relevant settings blocks
  if [[ "$cfg_type" == "settings" ]]; then
    settings="$(echo "$content" | jq '{
      permissions: (.permissions // {}),
      env: (.env // {}),
      hooks: (.hooks // {}),
      allowedMcpServers: (.allowedMcpServers // null),
      deniedMcpServers: (.deniedMcpServers // null),
      model: (.model // null)
    }' 2>/dev/null)" || settings="{}"
  fi

  local server_count
  server_count="$(echo "$servers" | jq 'length' 2>/dev/null)" || server_count=0

  jq -n \
    --arg path "$path" \
    --arg tier "$tier" \
    --arg type "$cfg_type" \
    --argjson server_count "$server_count" \
    --argjson servers "$servers" \
    --argjson settings "$settings" \
    '{
      path: $path,
      tier: $tier,
      type: $type,
      exists: true,
      server_count: $server_count,
      server_names: ($servers | keys),
      servers: $servers,
      settings: $settings
    }'
}

# ── Classify a server's transport and package handler ───────────────
classify_server() {
  local name="$1"
  local server_json="$2"
  local tier="$3"
  local source_file="$4"

  local transport
  transport="$(echo "$server_json" | jq -r '
    if .type then .type
    elif .url then "http"
    elif .command then "stdio"
    else "unknown"
    end
  ' 2>/dev/null)"

  local result
  result="$(jq -n \
    --arg name "$name" \
    --arg tier "$tier" \
    --arg source "$source_file" \
    --arg transport "$transport" \
    '{ name: $name, tier: $tier, source_file: $source, transport: $transport }'
  )"

  case "$transport" in
    stdio)
      local cmd args_json env_json cwd pkg_handler package
      cmd="$(echo "$server_json" | jq -r '.command // "unknown"')"
      args_json="$(echo "$server_json" | jq '.args // []')"
      env_json="$(echo "$server_json" | jq '.env // {}')"
      cwd="$(echo "$server_json" | jq -r '.cwd // "not set"')"

      # Detect package handler
      case "$cmd" in
        npx)   pkg_handler="npx" ;;
        uvx)   pkg_handler="uvx" ;;
        bunx)  pkg_handler="bunx" ;;
        docker) pkg_handler="docker" ;;
        node)  pkg_handler="node" ;;
        python|python3) pkg_handler="python" ;;
        deno)  pkg_handler="deno" ;;
        *)     pkg_handler="custom" ;;
      esac

      # Try to detect the package name from args
      package="$(echo "$args_json" | jq -r '
        [.[] | select(
          (startswith("-") | not) and
          (. != "-y") and
          (. != "--yes") and
          (. != "run") and
          (. != "exec") and
          (. != "--") and
          (. != "")
        )] | first // "unknown"
      ' 2>/dev/null)"

      # Redact env vars
      local redacted_env
      redacted_env="$(redact_json_object "$env_json")"

      # Check for ${VAR} references in env values (POSIX-compatible, no grep -P)
      local env_var_refs
      env_var_refs="$(echo "$env_json" | jq -r 'to_entries[] | select(.value | test("\\$\\{")) | .value' 2>/dev/null | \
        grep -o '\${[^}][^}]*}' 2>/dev/null | sort -u | while read -r ref; do
          varname="${ref#\$\{}"
          varname="${varname%\}}"
          varname="${varname%%:-*}"
          if [[ -n "${!varname:-}" ]]; then
            echo "$varname=SET"
          else
            echo "$varname=UNSET"
          fi
        done | jq -Rn '[inputs | split("=") | { (.[0]): .[1] }] | add // {}' 2>/dev/null)" || env_var_refs='{}'

      # Provide safe default for env_var_refs (avoid bash nested-brace parsing issues)
      local empty_json='{}'
      result="$(echo "$result" | jq \
        --arg cmd "$cmd" \
        --argjson args "$args_json" \
        --argjson env "$redacted_env" \
        --arg cwd "$cwd" \
        --arg pkg_handler "$pkg_handler" \
        --arg package "$package" \
        --argjson env_var_refs "${env_var_refs:-$empty_json}" \
        '. + {
          command: $cmd,
          args: $args,
          env: $env,
          cwd: $cwd,
          package_handler: $pkg_handler,
          package: $package,
          env_var_refs: $env_var_refs
        }'
      )"
      ;;

    http|sse)
      local url headers_json
      url="$(echo "$server_json" | jq -r '.url // "not set"')"
      headers_json="$(echo "$server_json" | jq '.headers // {}')"

      # Redact headers for display
      local redacted_headers
      redacted_headers="$(redact_json_object "$headers_json")"

      # Store both original (for health check) and redacted (for display)
      result="$(echo "$result" | jq \
        --arg url "$url" \
        --argjson headers "$redacted_headers" \
        --argjson original_headers "$headers_json" \
        '. + { url: $url, headers: $headers, original_headers: $original_headers }'
      )"
      ;;
  esac

  echo "$result"
}

# ── Health check a single server ────────────────────────────────────
health_check_server() {
  local server_json="$1"

  local name transport health issues
  name="$(echo "$server_json" | jq -r '.name')"
  transport="$(echo "$server_json" | jq -r '.transport')"
  health="healthy"
  issues="[]"

  add_issue() {
    local level="$1" msg="$2"
    issues="$(echo "$issues" | jq --arg l "$level" --arg m "$msg" '. + [{ level: $l, message: $m }]')"
    if [[ "$level" == "error" ]]; then
      health="error"
    elif [[ "$level" == "warning" && "$health" != "error" ]]; then
      health="warning"
    fi
  }

  case "$transport" in
    stdio)
      local cmd pkg_handler
      cmd="$(echo "$server_json" | jq -r '.command')"
      pkg_handler="$(echo "$server_json" | jq -r '.package_handler')"

      # Check if command binary exists
      local binary_path
      binary_path="$(command -v "$cmd" 2>/dev/null)" || binary_path=""

      if [[ -z "$binary_path" ]]; then
        add_issue "error" "Command '$cmd' not found in PATH"
      else
        # Check if executable
        if [[ ! -x "$binary_path" ]]; then
          add_issue "error" "Command '$cmd' found at $binary_path but is not executable"
        fi
      fi

      # Package handler specific checks
      case "$pkg_handler" in
        npx)
          if command -v npx &>/dev/null; then
            local node_version
            node_version="$(node --version 2>/dev/null)" || node_version="unknown"
            local npm_version
            npm_version="$(npm --version 2>/dev/null)" || npm_version="unknown"
            server_json="$(echo "$server_json" | jq \
              --arg nv "$node_version" --arg npmv "$npm_version" \
              '. + { node_version: $nv, npm_version: $npmv }')"
          else
            add_issue "error" "npx not found — install Node.js"
          fi
          ;;
        uvx)
          if command -v uvx &>/dev/null; then
            local uv_version
            uv_version="$(uvx --version 2>/dev/null)" || uv_version="unknown"
            server_json="$(echo "$server_json" | jq --arg v "$uv_version" '. + { uvx_version: $v }')"
          else
            add_issue "error" "uvx not found — install uv (https://docs.astral.sh/uv/)"
          fi
          ;;
        docker)
          if command -v docker &>/dev/null; then
            local docker_check=false
            if command -v timeout &>/dev/null; then
              timeout 5 docker info &>/dev/null && docker_check=true
            else
              docker info &>/dev/null && docker_check=true
            fi
            if [[ "$docker_check" == true ]]; then
              server_json="$(echo "$server_json" | jq '. + { docker_running: true }')"
              # Check if image exists
              local image
              image="$(echo "$server_json" | jq -r '.args[0] // ""')"
              if [[ -n "$image" ]] && ! docker image inspect "$image" &>/dev/null; then
                add_issue "warning" "Docker image '$image' not found locally (will be pulled on first run)"
              fi
            else
              add_issue "error" "Docker is installed but the daemon is not running"
              server_json="$(echo "$server_json" | jq '. + { docker_running: false }')"
            fi
          else
            add_issue "error" "docker not found in PATH"
          fi
          ;;
        python)
          if command -v "$cmd" &>/dev/null; then
            local py_version
            py_version="$("$cmd" --version 2>/dev/null)" || py_version="unknown"
            server_json="$(echo "$server_json" | jq --arg v "$py_version" '. + { python_version: $v }')"
          fi
          ;;
        node)
          if command -v node &>/dev/null; then
            local node_ver
            node_ver="$(node --version 2>/dev/null)" || node_ver="unknown"
            server_json="$(echo "$server_json" | jq --arg v "$node_ver" '. + { node_version: $v }')"
          fi
          ;;
        deno)
          if command -v deno &>/dev/null; then
            local deno_ver
            deno_ver="$(deno --version 2>/dev/null | head -1)" || deno_ver="unknown"
            server_json="$(echo "$server_json" | jq --arg v "$deno_ver" '. + { deno_version: $v }')"
          else
            add_issue "error" "deno not found in PATH"
          fi
          ;;
      esac

      # Resolve full command line for debugging
      local full_cmd
      full_cmd="$(echo "$server_json" | jq -r '[.command] + .args | join(" ")')"
      server_json="$(echo "$server_json" | jq --arg fc "$full_cmd" '. + { resolved_command: $fc }')"
      ;;

    http|sse)
      local url
      url="$(echo "$server_json" | jq -r '.url')"

      if [[ "$url" == "not set" || -z "$url" ]]; then
        add_issue "error" "No URL configured"
      else
        # Validate URL format
        if [[ ! "$url" =~ ^https?:// ]]; then
          add_issue "error" "Invalid URL format (must start with http:// or https://)"
        fi

        # Check for authentication configuration
        local has_headers
        has_headers="$(echo "$server_json" | jq '.headers | length > 0')"
        if [[ "$has_headers" == "true" ]]; then
          server_json="$(echo "$server_json" | jq '. + { auth_configured: true }')"
        else
          server_json="$(echo "$server_json" | jq '. + { auth_configured: false }')"
        fi

        # MCP protocol health check - send proper initialize message
        local mcp_initialize_payload
        mcp_initialize_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-diagnostic","version":"1.0.0"}}}'

        # Use original_headers (not redacted) for actual health check
        local headers_json
        headers_json="$(echo "$server_json" | jq -r '.original_headers // .headers // {}')"

        local http_code="000"
        local response_body=""

        if [[ "$HAS_CURL" == true ]]; then
          # Build curl args as an array (safe — no eval, no shell injection)
          local -a curl_args=( -sS --max-time 10 -H "Content-Type: application/json" )

          # Add configured headers safely
          if [[ "$(echo "$headers_json" | jq 'length')" -gt 0 ]]; then
            while IFS=$'\t' read -r key val; do
              curl_args+=( -H "$key: $val" )
            done < <(echo "$headers_json" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')
          fi

          curl_args+=( -X POST -d "$mcp_initialize_payload" "$url" )

          # Execute: get HTTP status code
          http_code="$(curl -o /dev/null -w '%{http_code}' "${curl_args[@]}" 2>/dev/null)" || http_code="000"

          # Execute again to capture response body for MCP validation
          response_body="$(curl "${curl_args[@]}" 2>/dev/null)" || response_body=""
        else
          add_issue "warning" "curl not found — cannot perform HTTP health check"
        fi

        server_json="$(echo "$server_json" | jq --arg hc "$http_code" '. + { http_status: $hc }')"

        # Validate MCP response
        local is_valid_mcp=false
        if [[ -n "$response_body" ]]; then
          # Check if response is valid JSON-RPC 2.0 with result or error
          if echo "$response_body" | jq -e 'has("jsonrpc") and has("id") and (has("result") or has("error"))' &>/dev/null; then
            is_valid_mcp=true
            server_json="$(echo "$server_json" | jq '. + { mcp_response: "valid" }')"
          else
            server_json="$(echo "$server_json" | jq '. + { mcp_response: "invalid" }')"
          fi
        fi

        # Detect known OAuth servers
        local is_oauth_server=false
        case "$url" in
          *mcp.atlassian.com*)
            is_oauth_server=true
            ;;
        esac

        case "$http_code" in
          000)
            add_issue "error" "Could not reach $url (timeout or DNS failure)"
            ;;
          200)
            if [[ "$is_valid_mcp" == true ]]; then
              # Valid MCP response
              :
            else
              add_issue "warning" "Server returned HTTP 200 but not a valid MCP JSON-RPC response"
            fi
            ;;
          401|403)
            if [[ "$has_headers" == "false" ]]; then
              if [[ "$is_oauth_server" == true ]]; then
                # OAuth server - 401 without headers is expected (credentials managed by Claude CLI)
                server_json="$(echo "$server_json" | jq '. + { oauth_managed: true }')"
                # Don't add an issue - this is normal for OAuth servers
              else
                add_issue "error" "Server returned $http_code — authentication required but no headers configured"
              fi
            else
              add_issue "warning" "Server returned $http_code — authentication may be invalid or expired"
            fi
            ;;
          404)
            add_issue "error" "Server returned 404 — URL may be incorrect"
            ;;
          405)
            add_issue "warning" "Server returned 405 — endpoint may not support MCP protocol"
            ;;
          5*)
            add_issue "error" "Server returned $http_code — server-side error"
            ;;
          *)
            add_issue "warning" "Server returned unexpected HTTP status: $http_code"
            ;;
        esac
      fi
      ;;

    *)
      add_issue "error" "Unknown transport type: $transport"
      ;;
  esac

  echo "$server_json" | jq \
    --arg health "$health" \
    --argjson issues "$issues" \
    '. + { health: $health, issues: $issues }'
}

# ── Detect conflicts/shadows across tiers ───────────────────────────
detect_conflicts() {
  local all_servers_json="$1"

  echo "$all_servers_json" | jq '
    group_by(.name) |
    map(select(length > 1)) |
    map({
      server_name: .[0].name,
      defined_in: [.[] | { tier: .tier, source_file: .source_file }],
      winning_tier: .[0].tier,
      shadowed_tiers: [.[1:][] | .tier]
    })
  '
}

# ── Audit settings for MCP relevance ───────────────────────────────
audit_settings() {
  local config_files_json="$1"

  echo "$config_files_json" | jq '[
    .[] |
    select(.type == "settings" and .exists == true) |
    {
      tier: .tier,
      path: .path,
      permissions: .settings.permissions,
      env: .settings.env,
      hooks: (.settings.hooks | keys // []),
      hook_details: .settings.hooks,
      allowed_mcp_servers: .settings.allowedMcpServers,
      denied_mcp_servers: .settings.deniedMcpServers,
      model: .settings.model,
      has_mcp_permissions: (
        ((.settings.permissions.allow // []) | map(select(test("mcp|MCP"; "i"))) | length > 0) or
        ((.settings.permissions.deny // []) | map(select(test("mcp|MCP"; "i"))) | length > 0)
      )
    }
  ]'
}

# ── Try to get CLI MCP list ─────────────────────────────────────────
get_cli_mcp_list() {
  if command -v claude &>/dev/null; then
    local output
    if command -v timeout &>/dev/null; then
      output="$(timeout 5 claude mcp list 2>&1 </dev/null)" || output="(claude mcp list timed out or failed — this is normal outside an interactive session)"
    else
      # macOS without coreutils: no timeout command available
      output="$(claude mcp list 2>&1 </dev/null)" || output="(claude mcp list failed — this is normal outside an interactive session)"
    fi
    echo "$output"
  else
    echo "(claude CLI not found in PATH — config files were parsed directly instead)"
  fi
}

# ═══════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════
main() {
  # ── 1. Discover config file paths ──
  local config_paths
  config_paths="$(get_config_paths)"

  # ── 2. Read and parse each config file ──
  local config_files="[]"
  while IFS= read -r entry; do
    local path tier cfg_type
    path="$(echo "$entry" | jq -r '.path')"
    tier="$(echo "$entry" | jq -r '.tier')"
    cfg_type="$(echo "$entry" | jq -r '.type')"

    local parsed
    parsed="$(read_config_file "$path" "$tier" "$cfg_type")"
    config_files="$(echo "$config_files" | jq --argjson p "$parsed" '. + [$p]')"
  done < <(echo "$config_paths" | jq -c '.[]')

  # ── 3. Extract all servers with tier info ──
  # Order defines precedence: first occurrence of a name wins
  local all_servers="[]"
  while IFS= read -r cfg; do
    local tier source_path servers_obj
    tier="$(echo "$cfg" | jq -r '.tier')"
    source_path="$(echo "$cfg" | jq -r '.path')"
    servers_obj="$(echo "$cfg" | jq '.servers // {}')"

    local server_count
    server_count="$(echo "$servers_obj" | jq 'length')"
    if [[ "$server_count" -gt 0 ]]; then
      while IFS= read -r srv_name; do
        local srv_json classified
        srv_json="$(echo "$servers_obj" | jq --arg n "$srv_name" '.[$n]')"
        classified="$(classify_server "$srv_name" "$srv_json" "$tier" "$source_path")"
        all_servers="$(echo "$all_servers" | jq --argjson s "$classified" '. + [$s]')"
      done < <(echo "$servers_obj" | jq -r 'keys[]')
    fi
  done < <(echo "$config_files" | jq -c '.[]')

  # ── 4. Health check each unique server (winner only) ──
  local effective_servers="[]"
  local checked_names=""
  local health_results="[]"

  while IFS= read -r srv; do
    local srv_name
    srv_name="$(echo "$srv" | jq -r '.name')"
    # Skip if already checked (first occurrence wins)
    if echo "$checked_names" | grep -qF "|${srv_name}|"; then
      continue
    fi
    checked_names="${checked_names}|${srv_name}|"

    local health_result
    health_result="$(health_check_server "$srv")"
    # Remove original_headers from output (they're only for health checking, not display)
    health_result="$(echo "$health_result" | jq 'del(.original_headers)')"
    health_results="$(echo "$health_results" | jq --argjson h "$health_result" '. + [$h]')"
    effective_servers="$(echo "$effective_servers" | jq --argjson s "$health_result" '. + [$s]')"
  done < <(echo "$all_servers" | jq -c '.[]')

  # ── 5. Detect conflicts ──
  local conflicts
  conflicts="$(detect_conflicts "$all_servers")"

  # ── 6. Audit settings ──
  local settings_audit
  settings_audit="$(audit_settings "$config_files")"

  # ── 7. CLI MCP list ──
  local cli_output
  cli_output="$(get_cli_mcp_list)"

  # ── 8. Environment info ──
  local env_info
  env_info="$(jq -n \
    --arg shell "${SHELL:-unknown}" \
    --arg path "${PATH:-}" \
    --arg node "$(node --version 2>/dev/null || echo 'not installed')" \
    --arg npm "$(npm --version 2>/dev/null || echo 'not installed')" \
    --arg python "$(python3 --version 2>/dev/null || echo 'not installed')" \
    --arg uv "$(uv --version 2>/dev/null || echo 'not installed')" \
    --arg docker "$(docker --version 2>/dev/null || echo 'not installed')" \
    '{
      shell: $shell,
      path_dirs: ($path | split(":")),
      runtimes: {
        node: $node,
        npm: $npm,
        python: $python,
        uv: $uv,
        docker: $docker
      }
    }'
  )"

  # ── 9. Summary stats ──
  local total_servers healthy warning errored total_configs
  total_servers="$(echo "$effective_servers" | jq 'length')"
  healthy="$(echo "$effective_servers" | jq '[.[] | select(.health == "healthy")] | length')"
  warning="$(echo "$effective_servers" | jq '[.[] | select(.health == "warning")] | length')"
  errored="$(echo "$effective_servers" | jq '[.[] | select(.health == "error")] | length')"
  total_configs="$(echo "$config_files" | jq '[.[] | select(.exists == true)] | length')"
  local total_checked
  total_checked="$(echo "$config_files" | jq 'length')"

  # ── Assemble final output (with section filtering) ──
  local full_output
  full_output="$(jq -n \
    --arg platform "$PLATFORM" \
    --arg project_root "$PROJECT_ROOT" \
    --arg cwd "$PROJECT_DIR" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson config_files "$config_files" \
    --argjson all_servers_all_tiers "$all_servers" \
    --argjson effective_servers "$effective_servers" \
    --argjson conflicts "$conflicts" \
    --argjson settings_audit "$settings_audit" \
    --arg cli_mcp_list "$cli_output" \
    --argjson environment "$env_info" \
    --argjson total_servers "$total_servers" \
    --argjson healthy "$healthy" \
    --argjson warning "$warning" \
    --argjson errored "$errored" \
    --argjson configs_found "$total_configs" \
    --argjson configs_checked "$total_checked" \
    '{
      meta: {
        timestamp: $timestamp,
        platform: $platform,
        project_root: $project_root,
        cwd: $cwd
      },
      config_files: $config_files,
      all_servers_all_tiers: $all_servers_all_tiers,
      effective_servers: $effective_servers,
      conflicts: $conflicts,
      settings_audit: $settings_audit,
      cli_mcp_list: $cli_mcp_list,
      environment: $environment,
      summary: {
        configs_checked: $configs_checked,
        configs_found: $configs_found,
        total_servers: $total_servers,
        healthy: $healthy,
        warning: $warning,
        error: $errored,
        conflicts: ($conflicts | length)
      }
    }'
  )"

  # Apply section filter
  case "$SECTION" in
    all)
      echo "$full_output"
      ;;
    configs)
      echo "$full_output" | jq '{ meta, config_files, summary }'
      ;;
    servers)
      echo "$full_output" | jq '{ meta, effective_servers, all_servers_all_tiers, conflicts, summary }'
      ;;
    health)
      echo "$full_output" | jq '{ meta, effective_servers, environment, cli_mcp_list, summary }'
      ;;
    settings)
      echo "$full_output" | jq '{ meta, settings_audit, summary }'
      ;;
    *)
      echo "$full_output"
      ;;
  esac
}

main
