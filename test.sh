#!/bin/bash
# Offline tests for agent.sh: a fake curl in PATH replays canned API responses.
# Usage: bash test.sh

cd "$(dirname "$0")"
export T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/curl" <<'CURL'
#!/bin/bash
n=$(( $(cat "$T/n") + 1 )); echo $n > "$T/n"
cat > "$T/req_$n.json"
cat "$T/resp_$n" 2>/dev/null
CURL
chmod +x "$T/bin/curl"

pass=0; fail=0
ok()  { ((pass++)); echo "ok   $1"; }
bad() { ((fail++)); echo "FAIL $1: $2"; }
eq()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has() { grep -qF -- "$2" "$T/out" && ok "$1" || bad "$1" "output missing [$2]"; }

# Canned responses for successive API calls
resp() { rm -f "$T"/resp_*; local i=0; for r in "$@"; do ((i++)); printf '%s' "$r" > "$T/resp_$i"; done; }
text() { jq -nc --arg c "$1" '{choices:[{message:{role:"assistant",content:$c}}]}'; }
tool() { jq -nc '$ARGS.positional as $a | {choices:[{message:{role:"assistant",content:null,tool_calls:
    [range(0; $a|length; 2) as $i | {id:$a[$i], type:"function", function:{name:"run_script", arguments:({script:$a[$i+1]}|tojson)}}]}}]}' --args "$@"; }

# Run agent.sh with the given input lines (then "exit")
run() {
    echo 0 > "$T/n"; echo "[]" > "$T/h.json"
    printf '%s\n' "$@" exit | AUTO= PATH="$T/bin:$PATH" OPENROUTER_API_KEY=test \
        HISTORY_FILE="$T/h.json" SYSTEM_PROMPT_FILE=system_prompt.txt bash agent.sh > "$T/out" 2>&1
}
roles() { jq -r '[.[].role] | join(",")' "$T/h.json"; }
tools() { jq -r '[.[] | select(.role=="tool") | .content] | join("|")' "$T/h.json"; }

echo "# text reply + request shape"
resp "$(text hi)"; run "q"
has "prints reply" "AI: hi"
eq  "history" "user,assistant" "$(roles)"
eq  "request" '{"model":"anthropic/claude-opus-5.5","tools":1,"cache":[true,true]}' \
    "$(jq -c '{model, tools:(.tools|length), cache:[.messages[0], .messages[-1] | has("cache_control")]}' "$T/req_1.json")"

echo "# tool calls: y runs, n skips"
resp "$(tool t1 'echo one' t2 'echo two')" "$(text done)"; run "q" y n
eq  "history" "user,assistant,tool,tool,assistant" "$(roles)"
eq  "tool results" "one|[Skipped by user]" "$(tools)"
has "final reply" "AI: done"

echo "# 'a' approves the rest"
resp "$(tool t1 'echo one' t2 'echo two')" "$(text done)"; run "q" a
eq  "tool results" "one|two" "$(tools)"

echo "# API errors print and drop the failed user message"
resp '{"error":{"message":"rate limited"}}' '{}' 'not json' '' "$(text ok)"; run a b c d e
has "error message" "Error: rate limited"
eq  "generic errors" "3" "$(grep -c 'Error: invalid API response' "$T/out")"
eq  "history" "user,assistant" "$(roles)"
eq  "kept prompt" "e" "$(jq -r '.[0].content' "$T/h.json")"

echo "# error mid tool loop keeps tool results"
resp "$(tool t1 'echo one')" 'not json' "$(text ok)"; run c y d
eq  "history" "user,assistant,tool,user,assistant" "$(roles)"
eq  "tool result" "one" "$(tools)"

echo; echo "$pass passed, $fail failed"
((fail == 0))
