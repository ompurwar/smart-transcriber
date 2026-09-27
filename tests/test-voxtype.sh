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
contains "config shows ollama"   "qwen2.5:1.5b"         "$(bash "$VOXTYPE" config)"

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
# Match loosely: the invocation has grown extra environment variables and a line
# continuation, and pinning the exact text made this test fail for a change that
# did not touch the filter at all.
m = re.search(r"out=\$\(printf '%s' \"\$resp\".*?python3 -c '\n(.*?)\n' 2>/dev/null\)", src, re.S)
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

# Only an *unbraced* $VAR followed by a multi-byte character is the bug. Bash
# reads the following byte as part of the variable name, so $REPO_URL<ellipsis>
# asks for a variable literally called "REPO_URL<ellipsis>" and dies with
# "unbound variable" under set -u. ${label}<ellipsis> is fine, because the
# closing brace ends the name and the ellipsis is ordinary output text.
pat = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")

out = []
for f in sorted(root.rglob("*")):
    if f.is_dir() or ".git" in f.parts:
        continue
    # This file holds the bad form on purpose, as a self-test below.
    if f.name == "test-voxtype.sh":
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
    ok "no unbraced \$VAR before a multi-byte character"
else
    bad "no unbraced \$VAR before a multi-byte character" "found at: $(echo "$suspect" | tr '\n' ' ')"
fi

# The guard above is the only thing standing between this bug and a release, so
# check that it still recognises both the bad form and the safe one.
if python3 - <<'PYU'
import re, sys
pat = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")
bad_forms = ['git clone "$REPO_URL…" done', "echo $FOO\u2026", "cp $TMP_X\u00b7"]
good_forms = ['info "installing ${label}…"', 'echo "$DIR/voxtype"', 'echo "${A}…"',
              'echo "cost: $5.00"', 'echo "${X}"']
if any(not pat.search(s) for s in bad_forms):
    sys.exit(1)
if any(pat.search(s) for s in good_forms):
    sys.exit(1)
PYU
then
    ok "the multi-byte guard catches the bug and spares the safe forms"
else
    bad "the multi-byte guard catches the bug and spares the safe forms" "regex is wrong"
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
    for pair in "v:hotkey" "delete:cancel" "r:restart"; do
        key="${pair%%:*}"; sub="${pair##*:}"
        if grep -q "key = \"$key\".*arg = \"$sub\"" "$hs"; then
            ok "binds $key -> $sub"
        else
            bad "binds $key -> $sub" "not found in share/hammerspoon.lua"
        fi
    done

    # The marker is what the installer waits for and doctor reports on, so it
    # must not be written when a bind failed.
    if grep -q 'pcall(hs.hotkey.bind' "$hs"; then
        ok "a failing bind cannot abort the config"
    else
        bad "a failing bind cannot abort the config" "hs.hotkey.bind is not wrapped in pcall"
    fi
    if grep -q 'hk:enable()' "$hs"; then
        ok "bound hotkeys are enabled explicitly"
    else
        bad "bound hotkeys are enabled explicitly" "no hk:enable() call"
    fi
    if grep -q 'bound == #BINDS' "$hs"; then
        ok "the load marker is gated on every hotkey binding"
    else
        bad "the load marker is gated on every hotkey binding" "marker is written unconditionally"
    fi
    if grep -q 'hotkeys PARTIAL' "$hs"; then
        ok "a partial load is reported as partial"
    else
        bad "a partial load is reported as partial" "no PARTIAL marker"
    fi
    if grep -q 'log.e(' "$hs"; then
        ok "bind failures are logged with hs.logger"
    else
        bad "bind failures are logged with hs.logger" "silent failure"
    fi
else
    bad "share/hammerspoon.lua exists" "missing"
fi

echo
echo "doctor understands the hotkey marker"
drv="$ROOT/bin/voxtype"
if grep -q 'hotkeys PARTIAL' "$drv"; then
    ok "doctor reports a partial bind instead of an all-clear"
else
    bad "doctor reports a partial bind instead of an all-clear" "no PARTIAL handling"
fi
if grep -q "sed -E 's/.\*hotkeys loaded (\[0-9T:-\]+).\*/" "$drv"; then
    ok "doctor still parses the timestamp from a full-load marker"
else
    bad "doctor still parses the timestamp from a full-load marker" "parse lost"
fi

echo
echo "overlay state file"
# The Hammerspoon overlay learns what voxtype is doing from ui.state, and it
# cannot work out the recording path for itself because it runs with a different
# environment. So the stage and the wav path both have to be published here.
STUB="$TMP/stub"
mkdir -p "$STUB"
cat > "$STUB/rec" <<'STUB'
#!/bin/bash
# Stand-in for sox rec: write the target file, then stay alive until signalled.
out=""
for a in "$@"; do out="$a"; done
[ -n "$out" ] && printf 'RIFF....WAVEfmt ' > "$out"
sleep 30
STUB
chmod +x "$STUB/rec"

UI="$VOXTYPE_STATE_DIR/ui.state"
rm -f "$UI"
PATH="$STUB:$PATH" bash "$VOXTYPE" start >/dev/null 2>&1
check "start publishes the recording stage" "recording" "$(cut -f1 < "$UI" 2>/dev/null)"
check "the state file is tab separated"     "3"         "$(awk -F'\t' '{print NF}' "$UI" 2>/dev/null)"
contains "start publishes the wav path"     "rec.wav"   "$(cut -f3 < "$UI" 2>/dev/null)"
if [ -n "$(cut -f2 < "$UI" 2>/dev/null)" ] && [ "$(cut -f2 < "$UI" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    ok "start publishes a unix timestamp"
else
    bad "start publishes a unix timestamp" "got [$(cut -f2 < "$UI" 2>/dev/null)]"
fi
PATH="$STUB:$PATH" bash "$VOXTYPE" cancel >/dev/null 2>&1
check "cancel publishes the cancelled stage" "cancelled" "$(cut -f1 < "$UI" 2>/dev/null)"
PATH="$STUB:$PATH" bash "$VOXTYPE" cancel >/dev/null 2>&1

# The two halves are only useful together, so check the module actually reads
# the file the binary writes.
if grep -q 'ui\.state' "$ROOT/share/hammerspoon.lua"; then
    ok "the Hammerspoon module reads ui.state"
else
    bad "the Hammerspoon module reads ui.state" "no reference in the module"
fi
if grep -q 'UI_STATE=.*\$STATE_DIR/ui\.state' "$VOXTYPE"; then
    ok "ui.state lives next to the rest of the state"
else
    bad "ui.state lives next to the rest of the state" "not derived from STATE_DIR"
fi

echo
echo "overlay tuning"
# 'voxtype overlay set' exists so the pill can be resized without editing
# hammerspoon.lua and reinstalling, which matters because the module reads its
# geometry once at load and Hammerspoon cannot see a new environment variable
# until the next login.
OVL="$VOXTYPE_STATE_DIR/overlay.conf"
rm -f "$OVL"
for k in VOXTYPE_PILL_W VOXTYPE_PILL_H VOXTYPE_PILL_R VOXTYPE_WAVE_H VOXTYPE_BARS VOXTYPE_TEXT_DY; do
    if grep -q "$k" "$VOXTYPE"; then
        ok "voxtype knows $k"
    else
        bad "voxtype knows $k" "not listed"
    fi
    if grep -q "$k" "$ROOT/share/hammerspoon.lua"; then
        ok "the module honours $k"
    else
        bad "the module honours $k" "not read by the module"
    fi
done
rm -f "$OVL"
bash "$VOXTYPE" overlay set PILL_H=52 WAVE_H=46 >/dev/null 2>&1
check "overlay set writes the pill height"    "VOXTYPE_PILL_H=52" "$(grep '^VOXTYPE_PILL_H=' "$OVL" 2>/dev/null)"
check "overlay set accepts a short key name"   "VOXTYPE_WAVE_H=46" "$(grep '^VOXTYPE_WAVE_H=' "$OVL" 2>/dev/null)"
bash "$VOXTYPE" overlay set pill_h=44 >/dev/null 2>&1
check "overlay set updates a key in place"    "1" "$(grep -c '^VOXTYPE_PILL_H=44$' "$OVL" 2>/dev/null)"
check "overlay set leaves the other key alone" "1" "$(grep -c '^VOXTYPE_WAVE_H=46$' "$OVL" 2>/dev/null)"
before=$(cat "$OVL" 2>/dev/null)
bash "$VOXTYPE" overlay set NOPE=1 >/dev/null 2>&1
check "overlay set rejects an unknown key"    "$before" "$(cat "$OVL" 2>/dev/null)"
bash "$VOXTYPE" overlay set PILL_H=abc >/dev/null 2>&1
check "overlay set rejects a non-number"      "$before" "$(cat "$OVL" 2>/dev/null)"
# '12abc' starts with a digit, so a check on the first character alone would
# have let it through.
bash "$VOXTYPE" overlay set PILL_H=12abc >/dev/null 2>&1
check "overlay set rejects trailing junk"     "$before" "$(cat "$OVL" 2>/dev/null)"
bash "$VOXTYPE" overlay set PILL_H= >/dev/null 2>&1
check "overlay set rejects an empty value"    "$before" "$(cat "$OVL" 2>/dev/null)"
bash "$VOXTYPE" overlay set PILL_H=-5 >/dev/null 2>&1
check "overlay set rejects a negative size"   "$before" "$(cat "$OVL" 2>/dev/null)"
bash "$VOXTYPE" overlay set TEXT_DY=-4 >/dev/null 2>&1
check "overlay set accepts a negative nudge"  "VOXTYPE_TEXT_DY=-4" "$(grep '^VOXTYPE_TEXT_DY=' "$OVL" 2>/dev/null)"
bash "$VOXTYPE" overlay set TEXT_DY=0 >/dev/null 2>&1
check "overlay set accepts a zero nudge"      "VOXTYPE_TEXT_DY=0" "$(grep '^VOXTYPE_TEXT_DY=' "$OVL" 2>/dev/null)"
bash "$VOXTYPE" overlay set >/dev/null 2>&1
check "overlay set with no arguments fails"   "1" "$?"
bash "$VOXTYPE" overlay reset >/dev/null 2>&1
if [ -f "$OVL" ]; then bad "overlay reset removes the conf" "still there"; else ok "overlay reset removes the conf"; fi
if grep -q 'overlay' "$ROOT/README.md"; then
    ok "the overlay is documented"
else
    bad "the overlay is documented" "not mentioned in the README"
fi

# Four bugs that all looked like styling complaints and were not. They are
# checked by looking for the thing that fixes each, because the Lua runs inside
# Hammerspoon and there is no way to exercise it from here.
if grep -q 'expired' "$ROOT/share/hammerspoon.lua"; then
    ok "the short-lived stages cannot pop back"
else
    bad "the short-lived stages cannot pop back" "no expired flag in the poller"
fi
if grep -q 'scaled(levels)' "$ROOT/share/hammerspoon.lua"; then
    ok "the auto-gain is actually applied to the bars"
else
    bad "the auto-gain is actually applied to the bars" "auto_gain runs but its result is unused"
fi
if grep -q 'BAR_MS' "$ROOT/share/hammerspoon.lua"; then
    ok "each bar covers a slice of time, not a fixed sample count"
else
    bad "each bar covers a slice of time, not a fixed sample count" "BAR_MS missing"
fi
if grep -q 'rate = (rate and rate > 0) and rate or 48000' "$ROOT/share/hammerspoon.lua"; then
    ok "the sample rate is read from the wav header"
else
    bad "the sample rate is read from the wav header" "no rate in parse_header"
fi

echo
echo "language models"
# Both defaults have to move together with the language. small.en cannot
# transcribe a non-English language at all, and qwen2.5:1.5b was measured
# translating Hindi into English instead of cleaning it, so pairing either of
# them with a non-English language is a silent failure.
cfg() { bash "$VOXTYPE" config; }
contains "en picks the English-only whisper"  "whisper     : small.en"     "$(VOXTYPE_LANGUAGE=en cfg)"
contains "en picks the small fast rewriter"   "ollama model: qwen2.5:1.5b" "$(VOXTYPE_LANGUAGE=en cfg)"
contains "hi picks the multilingual whisper"  "whisper     : small"        "$(VOXTYPE_LANGUAGE=hi cfg)"
contains "hi picks the bigger rewriter"       "ollama model: qwen2.5:7b"   "$(VOXTYPE_LANGUAGE=hi cfg)"
contains "en-US is still English"             "whisper     : small.en"     "$(VOXTYPE_LANGUAGE=en-US cfg)"
# An empty value means auto-detect, which must not be turned into English: the
# English-only pair cannot transcribe what auto-detect might find.
contains "empty language means auto-detect"   "language    : auto"         "$(VOXTYPE_LANGUAGE='' cfg)"
contains "auto-detect uses multilingual"      "whisper     : small"        "$(VOXTYPE_LANGUAGE='' cfg)"
contains "an explicit whisper still wins"     "whisper     : medium"       "$(VOXTYPE_LANGUAGE=hi VOXTYPE_WHISPER_MODEL=medium cfg)"
contains "an explicit rewriter still wins"    "ollama model: llama3.1:8b"  "$(VOXTYPE_LANGUAGE=hi VOXTYPE_OLLAMA_MODEL=llama3.1:8b cfg)"

echo
echo "script choice"
contains "hindi defaults to roman output"     "roman"    "$(VOXTYPE_LANGUAGE=hi cfg)"
contains "english stays native"               "native"   "$(VOXTYPE_LANGUAGE=en cfg)"
contains "script can be forced native"        "native"   "$(VOXTYPE_LANGUAGE=hi VOXTYPE_SCRIPT=native cfg)"
contains "script can be forced roman"         "roman"    "$(VOXTYPE_LANGUAGE=en VOXTYPE_SCRIPT=roman cfg)"

echo
echo "script guard"
# The guard is the part that is easy to get wrong and impossible to notice: a
# small model quietly translating Hindi into English still produces valid-looking
# Latin text. Rather than reason about the prompt, stand up a canned Ollama whose
# reply is read from a file, so each case can choose what the "model" says.
GUARD_PORT=$(( 20000 + RANDOM % 20000 ))
GUARD_REPLY="$TMP/guard-reply.json"
printf '%s' "{}" > "$GUARD_REPLY"
cat > "$TMP/guard_server.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, reply_file = int(sys.argv[1]), sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        # Keep the request so a test can see what the rewriter was actually
        # asked to clean, which is where the transliteration shows up.
        with open(reply_file + ".req", "wb") as f:
            f.write(body)
        with open(reply_file) as f:
            reply = json.load(f).get("response", "")
        out = json.dumps({"response": reply}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
python3 "$TMP/guard_server.py" "$GUARD_PORT" "$GUARD_REPLY" >/dev/null 2>&1 &
GUARD_PID=$!
for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$GUARD_PORT))==0 else 1)" && break
    sleep 0.1
done

hindi_in='नमस्ते यह एक परीक्षण है um मैं कल बारह बजे मिलूँगा like ठीक है'
try_guard() { # try_guard <model reply>
    printf '{"response": %s}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" > "$GUARD_REPLY"
    printf '%s' "$hindi_in" | VOXTYPE_LANGUAGE=hi VOXTYPE_OLLAMA_MODEL=qwen3:4b \
        VOXTYPE_OLLAMA_URL="http://127.0.0.1:$GUARD_PORT/api/generate" \
        VOXTYPE_STATE_DIR="$VOXTYPE_STATE_DIR" bash "$VOXTYPE" rewrite 2>/dev/null
}

# The model translated instead of transliterating. Latin script, so a check for
# Devanagari alone would wave it through; it must be caught and fall back.
check "english back from hindi input is rejected" "$hindi_in" \
    "$(try_guard 'Hello, this is a test. I will meet you at 7 tonight.')"
# Devanagari back when Roman was asked for: also rejected.
check "devanagari back from a roman request is rejected" "$hindi_in" \
    "$(try_guard 'नमस्ते यह एक परीक्षण है मैं कल मिलूँगा')"
# A real Hinglish rewrite must survive the guard, or the guard would be worse
# than the bug it is fixing.
check "a real hinglish rewrite is kept" "Theek hai, kal milte hain." \
    "$(try_guard 'Theek hai, kal milte hain.')"

echo
echo "transliteration"
# Whisper returns Devanagari and no model will convert it reliably, so the
# conversion has to happen before the rewriter is called. Check what the rewriter
# was actually sent: it must already be Latin, with no Devanagari left in it.
rm -f "$GUARD_REPLY.req"
try_guard 'Theek hai.' >/dev/null
sent=$(python3 -c "
import json, sys
try:
    body = json.load(open('$GUARD_REPLY.req'))
except Exception:
    sys.exit(0)
print(body.get('prompt', ''))
")
case "$sent" in
    *"नमस्ते"*) bad "devanagari is transliterated before the rewriter runs" "still Devanagari" ;;
    *namaste*)  ok  "devanagari is transliterated before the rewriter runs" ;;
    *)          bad "devanagari is transliterated before the rewriter runs" "no romanised text in the request" ;;
esac
if [ -n "$sent" ] && python3 -c "
import sys
sys.exit(0 if any('\u0900' <= c <= '\u097f' for c in sys.argv[1]) else 1)
" "$sent"; then
    bad "the rewriter is never shown Devanagari" "Devanagari found in the request"
else
    ok "the rewriter is never shown Devanagari"
fi

kill $GUARD_PID 2>/dev/null
wait 2>/dev/null

echo
echo "hotkey lock"
# Hammerspoon fires the hotkey without waiting, so two quick presses overlap and
# both can decide to stop-and-paste, which pastes the text twice.
LOCK="$VOXTYPE_STATE_DIR/hotkey.lock"
rm -rf "$LOCK"
sleep 30 & HOLDER=$!
mkdir -p "$LOCK" && printf '%s\n' "$HOLDER" > "$LOCK/pid"
out=$(VOXTYPE_STATE_DIR="$VOXTYPE_STATE_DIR" bash "$VOXTYPE" cancel 2>&1)
check "a held lock makes a second press a no-op" "" "$out"
kill "$HOLDER" 2>/dev/null
rm -rf "$LOCK"
mkdir -p "$LOCK"
printf '999999\n' > "$LOCK/pid"
# a lock whose owner is dead must not wedge dictation
VOXTYPE_STATE_DIR="$VOXTYPE_STATE_DIR" bash "$VOXTYPE" cancel >/dev/null 2>&1
if [ -d "$LOCK" ]; then
    bad "a dead lock holder is broken" "lock still present"
else
    ok "a dead lock holder is broken"
fi

echo
echo "overlay rounding"
# roundedRadius is not an attribute in this build of Hammerspoon and is dropped
# silently, which is why the corners stayed square through two rounds of
# "fixing" the radius value. Only roundedRectRadii draws them.
if grep -q 'roundedRectRadii' "$ROOT/share/hammerspoon.lua"; then
    ok "the overlay rounds corners with roundedRectRadii"
else
    bad "the overlay rounds corners with roundedRectRadii" "attribute missing"
fi
if grep -q 'roundedRadius' "$ROOT/share/hammerspoon.lua"; then
    bad "the silently-ignored roundedRadius is gone" "roundedRadius still present"
else
    ok "the silently-ignored roundedRadius is gone"
fi

# The newest bar has to be on the right so the waveform scrolls left like every
# other one the user has seen. The comment always said "drawn at the right" while
# the code put it at WAV_X, i.e. on the left, so it scrolled backwards.
if grep -q 'WAV_X + (BARS - 1 - i)' "$ROOT/share/hammerspoon.lua"; then
    ok "the waveform scrolls left, newest bar on the right"
else
    bad "the waveform scrolls left, newest bar on the right" "newest bar is not placed at the right edge"
fi

echo
echo "incomplete model"
# An interrupted download leaves the model directory behind with only part of
# the CoreML bundles, and every transcription then fails to load it. A directory
# test is not enough to call that model present.
HALF="$TMP/half-model"
mkdir -p "$HALF/MelSpectrogram.mlmodelc"
: > "$HALF/MelSpectrogram.mlmodelc/coremldata.bin"
out=$(VOXTYPE_MODEL_DIR="$HALF" VOXTYPE_STATE_DIR="$VOXTYPE_STATE_DIR" \
      bash "$VOXTYPE" doctor 2>&1)
contains "a half-downloaded model is not called ready" "incomplete" "$out"

echo
echo "installer"
for f in install.sh scripts/lib/common.sh scripts/preflight.sh scripts/setup-ollama.sh scripts/setup-app.sh tests/test-install.sh; do
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
