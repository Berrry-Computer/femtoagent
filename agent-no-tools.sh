#!/bin/bash

# Minimal CLI AI coding agent: OpenRouter + Claude, no tool calls (bash from code blocks), cache-optimized
# Deps: curl, jq, coreutils

[ -z "$OPENROUTER_API_KEY" ] && { echo "Error: OPENROUTER_API_KEY not set"; exit 1; }
command -v curl >/dev/null || { echo "Error: curl required"; exit 1; }
command -v jq >/dev/null || { echo "Error: jq required"; exit 1; }

ENDPOINT="${ENDPOINT:-https://openrouter.ai/api/v1/chat/completions}"
MODEL="${MODEL:-anthropic/claude-opus-5.5}"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-system_prompt.txt}"
HISTORY_FILE="${HISTORY_FILE:-history-no-tools.json}"   # separate from agent.sh (no tool messages here)
RESULT_FILE="${RESULT_FILE:-result.txt}"
SCRIPT_FILE="${SCRIPT_FILE:-generated_script.sh}"

[ -f "$HISTORY_FILE" ] || echo "[]" > "$HISTORY_FILE"
touch "$RESULT_FILE"
[ -f "$SYSTEM_PROMPT_FILE" ] || echo "You are a bash coding agent. Generate only the bash script code for the task, no text." > "$SYSTEM_PROMPT_FILE"

echo "femtoagent (no tools): 'exit' or ^D quits"

while true; do
    read -e -p $'\n› ' prompt || break   # EOF (Ctrl-D) exits
    [ "$prompt" = "exit" ] && break

    # Build user content with result context
    result_content=$(cat "$RESULT_FILE")
    [ -n "$result_content" ] && user_content="<previous-result>$result_content</previous-result>
<task>$prompt</task>" || user_content="<task>$prompt</task>"

    # Build messages: system (cached) + history (last cached) + new user
    messages=$(jq -n \
        --arg sys "$(cat "$SYSTEM_PROMPT_FILE")" \
        --slurpfile hist "$HISTORY_FILE" \
        --arg user "$user_content" '
        [{role:"system", content:$sys, cache_control:{type:"ephemeral"}}] +
        (if ($hist[0] | length) > 0 then ($hist[0][:-1] + [$hist[0][-1] + {cache_control:{type:"ephemeral"}}]) else [] end) +
        [{role:"user", content:$user}]
    ')

    body=$(jq -n --arg m "$MODEL" --argjson msgs "$messages" '{model:$m,messages:$msgs}')

    response=$(curl -s -X POST "$ENDPOINT" -H "Authorization: Bearer $OPENROUTER_API_KEY" -H "Content-Type: application/json" -d "$body")

    error=$(echo "$response" | jq -r '.error.message // empty')
    [ -n "$error" ] && { echo "Error: $error"; continue; }

    raw_response=$(echo "$response" | jq -r '.choices[0].message.content // "No script generated"')
    script=$(echo "$raw_response" | sed -n '/^```/,/^```$/p' | sed '1d;$d')
    [ -z "$script" ] && script="$raw_response"
    printf '\n$ %s\n' "$script"

    # Append to history
    jq --arg u "$user_content" --arg a "$script" '. + [{role:"user",content:$u},{role:"assistant",content:$a}]' "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

    [ "$script" = "No script generated" ] && continue
    echo "$script" > "$SCRIPT_FILE"

    read -e -p "Execute this script? (y/n): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] && bash "$SCRIPT_FILE" 2>&1 | tee "$RESULT_FILE"
done

echo "Goodbye!"
