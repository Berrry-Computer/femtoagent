#!/bin/bash

# Minimal CLI AI Coding Agent: OpenRouter, Claude Sonnet 4, tool-call based
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
    local msg="$1"
    jq --argjson m "$msg" '. + [$m]' "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
}

# Build messages array with system prompt and cache control
build_messages() {
    jq -n --arg sys "$(<"$SYSTEM_PROMPT_FILE")" --slurpfile h "$HISTORY_FILE" '
        [{role:"system",content:$sys,cache_control:{type:"ephemeral"}}] +
        (if ($h[0]|length)>0 then $h[0][:-1]+[$h[0][-1]+{cache_control:{type:"ephemeral"}}] else [] end)'
}

# Call the API
call_api() {
    local messages="$1"
    curl -s "$ENDPOINT" -H "Authorization: Bearer $OPENROUTER_API_KEY" -H "Content-Type: application/json" \
        -d "$(jq -nc --arg m "$MODEL" --argjson msg "$messages" --argjson t "$TOOLS" '{model:$m,messages:$msg,tools:$t}')"
}

echo "AI Coding Agent (proper tool protocol). Type 'exit' to quit."

while true; do
    read -e -p "You: " prompt
    [[ "$prompt" = "exit" ]] && break
    [[ -z "$prompt" ]] && continue

    # Add user message to history
    append_msg "$(jq -nc --arg c "$prompt" '{role:"user",content:$c}')"

    # Tool loop - keep calling API until we get a text response (no tool calls)
    while true; do
        messages=$(build_messages)
        resp=$(call_api "$messages")

        # Check for API errors
        err=$(echo "$resp" | jq -r '.error.message // empty')
        if [[ -n "$err" ]]; then
            echo "Error: $err"
            break
        fi

        # Extract assistant message
        assistant_msg=$(echo "$resp" | jq -c '.choices[0].message')
        tool_calls=$(echo "$assistant_msg" | jq -c '.tool_calls // empty')

        if [[ -n "$tool_calls" && "$tool_calls" != "null" && "$tool_calls" != "[]" ]]; then
            # Append assistant message with tool_calls to history
            append_msg "$assistant_msg"

            # Process each tool call
            tool_count=$(echo "$tool_calls" | jq 'length')
            all_approved=true
            
            for ((i=0; i<tool_count; i++)); do
                tool_call=$(echo "$tool_calls" | jq -c ".[$i]")
                tool_id=$(echo "$tool_call" | jq -r '.id')
                tool_name=$(echo "$tool_call" | jq -r '.function.name')
                tool_args=$(echo "$tool_call" | jq -r '.function.arguments')
                
                if [[ "$tool_name" == "run_script" ]]; then
                    script=$(echo "$tool_args" | jq -r '.script // empty')
                    echo "Script [$((i+1))/$tool_count]: $script"
                    
                    # Confirmation
                    if [[ "$AUTO" != "1" ]]; then
                        read -e -p "Run? (y/n/a=all): " c
                        [[ "$c" =~ ^[aA]$ ]] && AUTO=1
                        [[ ! "$c" =~ ^[yYaA]$ ]] && { 
                            append_msg "$(jq -nc --arg id "$tool_id" '{role:"tool",tool_call_id:$id,content:"[Skipped by user]"}')"
                            all_approved=false
                            continue
                        }
                    fi
                    
                    # Execute and capture result
                    result=$(bash -c "$script" 2>&1)
                    echo "$result"
                    
                    # Append tool result to history
                    append_msg "$(jq -nc --arg id "$tool_id" --arg c "$result" '{role:"tool",tool_call_id:$id,content:$c}')"
                else
                    echo "Unknown tool: $tool_name"
                    append_msg "$(jq -nc --arg id "$tool_id" '{role:"tool",tool_call_id:$id,content:"Unknown tool"}')"
                fi
            done
            
            # Continue loop to send tool results back to API
        else
            # No tool calls - final text response
            txt=$(echo "$assistant_msg" | jq -r '.content // "No response"')
            echo "AI: $txt"
            append_msg "$(jq -nc --arg c "$txt" '{role:"assistant",content:$c}')"
            break
        fi
    done
done
echo "Goodbye!"
