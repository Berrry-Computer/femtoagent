# FemtoAgent: Minimal CLI AI Coding Assistant

A lightweight bash-based AI coding agent that uses the OpenRouter API with native tool calls.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                           agent.sh                              │
│                   Tool-Call Based CLI Agent                     │
└─────────────────────────────────────────────────────────────────┘

    ┌──────────────────┐
    │   User Input     │
    │   "You: ___"     │
    └────────┬─────────┘
             │ append {role:"user"}
             ▼
    ┌──────────────────────────────────────────────────┐
    │  build_messages():                               │
    │  • System prompt              (cache_control)    │
    │  • history.json, last msg     (cache_control)    │
    └────────────────────┬─────────────────────────────┘
                         │
                         ▼
    ┌─────────────┐         ┌─────────────────┐
    │  agent.sh   │──curl──▶│  OpenRouter API │
    │  + TOOLS    │◀────────│  (Claude model) │
    └──────┬──────┘         └─────────────────┘
           │
           ├──────────────────────────────┐
           ▼                              ▼
    ┌──────────────┐              ┌───────────────┐
    │  tool_calls  │              │  Text reply   │
    │  run_script  │              │  "AI: ..."    │
    └──────┬───────┘              └───────┬───────┘
           │ for each call                │
           ▼                              ▼
    ┌──────────────────────┐       back to "You:"
    │ Show script          │
    │ Run? (y/n/a=all)     │── n ──▶ "[Skipped by user]"
    └────────┬─────────────┘                │
             │ y / a                        │
             ▼                              │
    ┌──────────────────────┐                │
    │ bash -c "$script"    │                │
    │ (stdout + stderr)    │                │
    └────────┬─────────────┘                │
             ▼                              │
    ┌──────────────────────────────────┐    │
    │ append {role:"tool",             │◀───┘
    │         tool_call_id, content}   │
    └────────┬─────────────────────────┘
             │
             └──▶ call API again (loop until text reply)
```

## Files

```
├── agent.sh           # Main agent (native tool calls)
├── agent-no-tools.sh  # Legacy agent: extracts bash from ```bash blocks,
│                      #   feeds output back via result.txt
├── system_prompt.txt  # Customizable system instructions
├── history.json       # Conversation memory (user/assistant/tool messages)
├── result.txt         # Last script output (agent-no-tools.sh only)
├── generated_script.sh# Last generated script (agent-no-tools.sh only)
└── test.sh            # Offline tests (fake curl)
```

## Usage

1. Set your OpenRouter API key:
```bash
export OPENROUTER_API_KEY="your-key"
```

2. Run the agent:
```bash
bash agent.sh
```

3. Describe tasks in plain English
4. Review each script and answer `y` (run), `n` (skip), or `a` (run this and all following without asking)
5. Type `exit` to quit

### Auto-execute mode
```bash
AUTO=1 bash agent.sh
```

### Reset conversation
```bash
echo "[]" > history.json
```

## Requirements

- curl
- jq
- coreutils

## Testing

Offline tests (no API key or network needed; a fake `curl` replays canned responses):
```bash
bash test.sh
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| OPENROUTER_API_KEY | (required) | Your OpenRouter API key |
| MODEL | anthropic/claude-opus-5.5 | Model to use |
| ENDPOINT | https://openrouter.ai/api/v1/chat/completions | API endpoint |
| SYSTEM_PROMPT_FILE | system_prompt.txt | System prompt path |
| HISTORY_FILE | history.json | Conversation history path |
| AUTO | 0 | Set to 1 to auto-execute scripts |

## How It Works

1. User describes a task in natural language; it is appended to history
2. Agent builds messages: system prompt + full history (prompt-cache markers on the system prompt and last message)
3. Sends request to OpenRouter with the `run_script` tool definition
4. AI responds with either:
   - **Tool call(s)**: each script is shown for confirmation, executed with `bash -c`, and its output appended as a `role:"tool"` message, then the API is called again
   - **Text**: displayed to the user, ending the turn
5. History persists in `history.json` across sessions
6. Prompt caching reduces API costs on repeated context
