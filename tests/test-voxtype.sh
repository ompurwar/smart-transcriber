#!/bin/bash
# Unit tests for voxtype. No models, no network, no microphone.
#
# Covers the parts that are easy to get wrong and hard to notice: dispatch,
# state tracking, and the filter that stops a small model answering the prompt
# instead of rewriting it.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOXTYPE="$ROOT/bin/voxtype"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }

check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

contains() { # contains <name> <needle> <haystack>
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1" "expected to contain [$2] in [$3]" ;;
    esac
}

# A private state dir keeps tests from touching the real runtime.
export VOXTYPE_STATE_DIR="$TMP/state"
mkdir -p "$VOXTYPE_STATE_DIR"

echo "voxtype tests"
echo

echo "dispatch"
check "help exits 0"            0 "$(bash "$VOXTYPE" help >/dev/null 2>&1; echo $?)"
contains "help lists doctor"    "doctor"        "$(bash "$VOXTYPE" help)"
contains "help lists hotkeys"   "ctrl+opt+V"    "$(bash "$VOXTYPE" help)"
check "status is idle"          "idle"          "$(bash "$VOXTYPE" status)"
check "version prints"         "0.1.0"         "$(bash "$VOXTYPE" version)"
check "unknown command is 2"   2               "$(bash "$VOXTYPE" nonsense >/dev/null 2>&1; echo $?)"
contains "unknown command hints" "try: voxtype help" "$(bash "$VOXTYPE" nonsense 2>&1)"

echo
echo "config"
contains "config shows version"  "version     : 0.1.0" "$(bash "$VOXTYPE" config)"
contains "config shows ollama"   "qwen2.5:3b"         "$(bash "$VOXTYPE" config)"

echo
echo "install-hint"
hint="$(bash "$VOXTYPE" install-hint)"
contains "hint covers microphone"  "Microphone"     "$hint"
contains "hint covers accessibility" "Accessibility" "$hint"

echo
echo "rewrite filter"
# The filter is the guard that stops conversational junk reaching the clipboard.
filter_src="$TMP/filter.py"
python3 - "$filter_src" <<'PY'
import pathlib, re, sys
src = pathlib.Path("bin/voxtype").read_text()
m = re.search(r"out=\$\(printf '%s' \"\$resp\" \| VOXTYPE_RAW=\"\$raw\" python3 -c '\n(.*?)\n' ", src, re.S)
if not m:
    sys.exit("could not locate the rewrite filter inside bin/voxtype")
pathlib.Path(sys.argv[1]).write_text(m.group(1))
PY

if [ ! -f "$filter_src" ]; then
    bad "filter extracted" "bin/voxtype no longer contains the expected filter block"
else
    ok "filter extracted"

    # The filter reads an ollama response as JSON on stdin and exits non-zero
    # to signal "reject, fall back to the raw transcript".
    for t in \
        "Can you send me the quarterly report before Friday?" \
        "I fixed the parser bug." \
        "Reminder: the invoice for 2026 totals 4,500 dollars."
    do
        json_body=$(python3 -c 'import json,sys; print(json.dumps({"response": sys.argv[1]}))' "$t")
        if printf '%s' "$json_body" | VOXTYPE_RAW="x" python3 "$filter_src" >/dev/null 2>&1; then
            ok "accepts: $(printf '%.40s' "$t")"
        else
            bad "accepts: $(printf '%.40s' "$t")" "a valid rewrite was rejected"
        fi
    done

    # Ordinary dictation that a naive guard would wrongly reject. These are the
    # phrases that made an earlier version of this filter unusable: "could you
    # please send me the report" is not the model asking for the input back.
    legit=(
        "Could you please send me the quarterly report before Friday?"
        "Would you like me to send it tomorrow?"
        "I am sorry, but I cannot make it on Friday."
        "I am sorry to hear that."
        "Sure, I will handle it."
        "As a reminder, the meeting is at three."
        "I cannot wait to see you."
        "Please send me the documents."
        "Would you like to book a table for four?"
        "I would like to cancel my subscription."
    )
    for t in "${legit[@]}"; do
        json_body=$(python3 -c 'import json,sys; print(json.dumps({"response": sys.argv[1]}))' "$t")
        if printf '%s' "$json_body" | VOXTYPE_RAW="x" python3 "$filter_src" >/dev/null 2>&1; then
            ok "accepts: $(printf '%.40s' "$t")"
        else
            bad "accepts: $(printf '%.40s' "$t")" "ordinary dictation was rejected"
        fi
    done

    junk=(
        "I'm sorry, but the text you've provided is entirely in raw speech-to-text format."
        "1. Fix obvious errors: the phrase is fine"
        "Step 1: analyze the transcript"
        "Here is the cleaned text: hello"
        "As an AI language model, I cannot do that."
        "Cleaned version: hello there"
        "---END---"
        "Could you please provide the original text so I can rewrite it?"
        "Please provide the text you would like me to clean up."
        "I cannot rewrite this without more context."
        "Sure, here is the polished version."
        "Your rewritten text is below."
    )
    for t in "${junk[@]}"; do
        json_body=$(python3 -c 'import json,sys; print(json.dumps({"response": sys.argv[1]}))' "$t")
        if printf '%s' "$json_body" | VOXTYPE_RAW="x" python3 "$filter_src" >/dev/null 2>&1; then
            bad "rejects: $(printf '%.40s' "$t")" "model output that should never be pasted was accepted"
        else
            ok "rejects: $(printf '%.40s' "$t")"
        fi
    done

    # A runaway generation that ignored the stop sequence must also be refused.
    long_body=$(python3 -c 'import json; print(json.dumps({"response": "word " * 4000}))')
    if printf '%s' "$long_body" | VOXTYPE_RAW="hi" python3 "$filter_src" >/dev/null 2>&1; then
        bad "rejects runaway output" "a 4000-word response was accepted"
    else
        ok "rejects runaway output"
    fi
fi

echo
echo "non-speech tag stripping"
strip_src="$TMP/strip.py"
python3 - "$strip_src" <<'PY2'
import pathlib, re, sys
src = pathlib.Path("bin/voxtype").read_text()
# strip_tags wraps a python3 -c '...' block; pull out just that program.
m = re.search(r"strip_tags\(\) \{.*?python3 -c '\n(.*?)\n' 2>/dev/null", src, re.S)
if not m:
    sys.exit("could not locate the strip_tags python block inside bin/voxtype")
pathlib.Path(sys.argv[1]).write_text(m.group(1))
PY2
if [ -f "$strip_src" ]; then
    ok "stripper extracted"
    strip_case() { # strip_case <name> <in> <expected>
        got=$(printf '%s' "$2" | python3 "$strip_src" 2>/dev/null)
        check "$1" "$3" "$got"
    }
    strip_case "removes [Music]"        "hello there [Music]"                  "hello there"
    strip_case "removes (laughter)"     "hello there (laughter)"              "hello there"
    strip_case "removes [BLANK_AUDIO]"  "one two [BLANK_AUDIO] three"         "one two three"
    strip_case "removes trailing tag"   "we should go [Music]"                "we should go"
    strip_case "keeps real brackets"    "call [the] office"                   "call [the] office"
    strip_case "keeps the word music"   "the music was loud"                  "the music was loud"
else
    bad "stripper extracted" "bin/voxtype no longer contains strip_tags"
fi

echo
echo "rewrite through the real script (fake ollama)"

# The filter tests above exercise the extracted python directly. These run the
# whole bash path, which is where an unescaped apostrophe inside the
# python3 -c block would break the script.
cat > "$TMP/fake_ollama.py" <<'PYFAKE'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

REPLY = open(sys.argv[2]).read()

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.dumps({"model": "fake", "response": REPLY, "done": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYFAKE

port=18731
start_fake() { # start_fake <reply>
    printf '%s' "$1" > "$TMP/reply.txt"
    python3 "$TMP/fake_ollama.py" "$port" "$TMP/reply.txt" &
    FAKE_PID=$!
    for _ in $(seq 1 25); do
        curl -s -o /dev/null -X POST "http://127.0.0.1:$port/" -d '{}' && break
        sleep 0.2
    done
}
stop_fake() { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }

start_fake "Could you please send me the quarterly report before Friday?"
got=$(printf 'um can you please send me the or quarterly report [Music]' \
    | VOXTYPE_OLLAMA_URL="http://127.0.0.1:$port/api/generate" bash "$VOXTYPE" rewrite 2>/dev/null)
stop_fake
check "uses the model reply" "Could you please send me the quarterly report before Friday?" "$got"

start_fake "Could you please provide the original text so I can rewrite it."
got=$(printf 'hello' \
    | VOXTYPE_OLLAMA_URL="http://127.0.0.1:$port/api/generate" bash "$VOXTYPE" rewrite 2>/dev/null)
stop_fake
check "falls back to raw on junk" "hello" "$got"

# Ollama unreachable: the transcript must still survive.
got=$(printf 'um the plain raw words' \
    | VOXTYPE_OLLAMA_URL="http://127.0.0.1:1/api/generate" VOXTYPE_OLLAMA_TIMEOUT=2 \
      bash "$VOXTYPE" rewrite 2>/dev/null)
check "falls back to raw when ollama is down" "um the plain raw words" "$got"

# A non-ASCII character straight after $VAR becomes part of the variable name,
# so `$REPO_URL...` with a real ellipsis fails at runtime. It only shows up on
# the piped-install path, which is the one every new user takes.
echo
echo "no unicode glued to a shell variable"
pyfiles=()
while IFS= read -r f; do pyfiles+=("$f"); done < <(find "$ROOT" -type f \
    \( -name '*.sh' -o -name '*.lua' -o -name '*.rb' -o -name '*.yml' -o -name 'voxtype' -o -name 'common.sh' \) \
    -not -path '*/.git/*')
suspect=$(python3 - "$ROOT" <<'PYU'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pat = re.compile(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[^\x00-\x7f]")
out = []
for f in sorted(root.rglob("*")):
    if f.is_dir() or ".git" in f.parts:
        continue
    if not (f.suffix in {".sh", ".lua", ".rb", ".yml"} or f.name == "voxtype"):
        continue
    try:
        for n, line in enumerate(f.read_text().splitlines(), 1):
            if pat.search(line):
                out.append("%s:%s" % (f.relative_to(root), n))
    except Exception:
        pass
print("\n".join(out))
PYU
)
if [ -z "$suspect" ]; then
    ok "no unicode after a shell variable"
else
    bad "no unicode after a shell variable" "found at: $(echo "$suspect" | tr '\n' ' ')"
fi

echo
echo "hammerspoon module"
hs="$ROOT/share/hammerspoon.lua"
if [ -f "$hs" ]; then
    ok "share/hammerspoon.lua exists"
    if grep -qE '^\s*require\(' "$hs"; then
        bad "no explicit require calls" "this Hammerspoon build hangs on require(\"hs.execute\")"
    else
        ok "no explicit require calls"
    fi
    for pair in "V:hotkey" "delete:cancel" "R:restart"; do
        key="${pair%%:*}"; sub="${pair##*:}"
        if grep -q "\"$key\", function() fire(\"$sub\")" "$hs"; then
            ok "binds $key -> $sub"
        else
            bad "binds $key -> $sub" "not found in share/hammerspoon.lua"
        fi
    done
else
    bad "share/hammerspoon.lua exists" "missing"
fi

echo
echo "installer"
for f in install.sh scripts/lib/common.sh scripts/setup-ollama.sh scripts/setup-app.sh; do
    if bash -n "$ROOT/$f" 2>/dev/null; then ok "syntax: $f"; else bad "syntax: $f" "bash -n failed"; fi
done
if [ -f "$ROOT/install.sh" ] && grep -q -- "--uninstall" "$ROOT/install.sh"; then
    ok "installer supports --uninstall"
else
    bad "installer supports --uninstall" "flag missing"
fi
if [ -f "$ROOT/packaging/homebrew/voxtype.rb" ] && grep -q "class Voxtype" "$ROOT/packaging/homebrew/voxtype.rb"; then
    ok "homebrew formula present"
else
    bad "homebrew formula present" "missing or malformed"
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m%d passed, 0 failed\033[0m\n' "$pass"
    exit 0
else
    printf '\033[31m%d passed, %d failed\033[0m\n' "$pass" "$fail"
    exit 1
fi
