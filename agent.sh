#!/bin/bash

# Minimal CLI AI coding agent: OpenRouter + Claude, native tool calls
# Deps: curl, jq, coreutils

[ -z "$OPENROUTER_API_KEY" ] && { echo "Error: OPENROUTER_API_KEY not set"; exit 1; }
command -v curl >/dev/null || { echo "Error: curl required"; exit 1; }
command -v jq >/dev/null || { echo "Error: jq required"; exit 1; }

# Configuration via environment variables
ENDPOINT="${ENDPOINT:-https://openrouter.ai/api/v1/chat/completions}"
MODEL="${MODEL:-anthropic/claude-opus-5.5}"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-system_prompt.txt}"
HISTORY_FILE="${HISTORY_FILE:-history.json}"

# Initialize files
[ -f "$HISTORY_FILE" ] || echo "[]" > "$HISTORY_FILE"
[ -f "$SYSTEM_PROMPT_FILE" ] || echo "You are a bash coding agent. Use the run_script tool to execute bash commands." > "$SYSTEM_PROMPT_FILE"

TOOLS='[{"type":"function","function":{"name":"run_script","description":"Execute bash script","parameters":{"type":"object","properties":{"script":{"type":"string"}},"required":["script"]}}}]'

# Append a message object to history
append_msg() {
    jq --argjson m "$1" '. + [$m]' "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
}

# Append a tool result: tool_result <tool_call_id> <content>
tool_result() {
    append_msg "$(jq -nc --arg id "$1" --arg c "$2" '{role:"tool",tool_call_id:$id,content:$c}')"
}

# Drop a trailing user message whose turn failed (keeps history alternating)
drop_last_user() {
    jq 'if .[-1].role=="user" then .[:-1] else . end' "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
}

# Build request (system prompt + history, cache markers on system and last message) and send it
call_api() {
    jq -nc --arg m "$MODEL" --arg sys "$(<"$SYSTEM_PROMPT_FILE")" --slurpfile h "$HISTORY_FILE" --argjson t "$TOOLS" '
        {model:$m, tools:$t, messages:
            ([{role:"system",content:$sys,cache_control:{type:"ephemeral"}}] +
             ($h[0] | if length>0 then .[:-1] + [.[-1] + {cache_control:{type:"ephemeral"}}] else . end))}' |
    curl -s "$ENDPOINT" -H "Authorization: Bearer $OPENROUTER_API_KEY" -H "Content-Type: application/json" --data-binary @-
}

echo "AI Coding Agent (proper tool protocol). Type 'exit' to quit."

while true; do
    read -e -p "You: " prompt || break   # EOF (Ctrl-D) exits
    [[ "$prompt" = "exit" ]] && break
    [[ -z "$prompt" ]] && continue

    append_msg "$(jq -nc --arg c "$prompt" '{role:"user",content:$c}')"

    # Tool loop: keep calling the API until the reply has no tool calls
    while true; do
        resp=$(call_api)
        msg=$(jq -c '.choices[0].message // empty' <<<"$resp" 2>/dev/null)
        [[ -z "$msg" ]] && { err=$(jq -r '.error.message // empty' <<<"$resp" 2>/dev/null); echo "Error: ${err:-invalid API response}"; drop_last_user; break; }

        append_msg "$msg"

        if ! jq -e '.tool_calls | length > 0' <<<"$msg" >/dev/null; then
            echo "AI: $(jq -r '.content // "No response"' <<<"$msg")"
            break
        fi

        n=$(jq '.tool_calls | length' <<<"$msg")
        i=0
        # fd 3 keeps stdin free for the confirmation prompt and the scripts
        while read -r -u 3 tc; do
            ((i++))
            id=$(jq -r '.id' <<<"$tc")
            script=$(jq -r '.function.arguments | fromjson | .script // empty' <<<"$tc")
            echo "Script [$i/$n]: $script"

            if [[ "$AUTO" != "1" ]]; then
                read -e -p "Run? (y/n/a=all): " c
                [[ "$c" =~ ^[aA]$ ]] && AUTO=1
                [[ "$c" =~ ^[yYaA]$ ]] || { tool_result "$id" "[Skipped by user]"; continue; }
            fi

            result=$(bash -c "$script" 2>&1)
            echo "$result"
            tool_result "$id" "$result"
        done 3< <(jq -c '.tool_calls[]' <<<"$msg")
    done
done
echo "Goodbye!"
