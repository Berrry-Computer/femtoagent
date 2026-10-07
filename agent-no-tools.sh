#!/bin/bash

# Minimal CLI AI coding agent: OpenRouter + Claude, no tool calls (bash from code blocks), cache-optimized
# Deps: curl, jq, coreutils

[ -z "$OPENROUTER_API_KEY" ] && { echo "Error: OPENROUTER_API_KEY not set"; exit 1; }
command -v curl >/dev/null || { echo "Error: curl required"; exit 1; }
command -v jq >/dev/null || { echo "Error: jq required"; exit 1; }

ENDPOINT="${ENDPOINT:-https://openrouter.ai/api/v1/chat/completions}"
MODEL="${MODEL:-anthropic/claude-opus-4.5}"
SCRIPT_FILE="${SCRIPT_FILE:-generated_script.sh}"

[ -f history.json ] || echo "[]" > history.json
touch result.txt
[ -f system_prompt.txt ] || echo "You are a bash coding agent. Generate only the bash script code for the task, no text." > system_prompt.txt

echo "Welcome to AI Coding Agent. Describe task; I'll generate/execute bash. Type 'exit' to quit."

while true; do
    read -e -p "You: " prompt
    [ "$prompt" = "exit" ] && break

    # Build user content with result context
    result_content=$(cat result.txt)
    [ -n "$result_content" ] && user_content="<previous-result>$result_content</previous-result>
<task>$prompt</task>" || user_content="<task>$prompt</task>"

    # Build messages: system (cached) + history (last cached) + new user
    messages=$(jq -n \
        --arg sys "$(cat system_prompt.txt)" \
        --slurpfile hist history.json \
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
    echo "AI Generated Script: $script"

    # Append to history.json
    jq --arg u "$user_content" --arg a "$script" '. + [{role:"user",content:$u},{role:"assistant",content:$a}]' history.json > history.json.tmp && mv history.json.tmp history.json

    [ "$script" = "No script generated" ] && continue
    echo "$script" > "$SCRIPT_FILE"

    read -e -p "Execute this script? (y/n): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] && bash "$SCRIPT_FILE" 2>&1 | tee result.txt
done

echo "Goodbye!"
