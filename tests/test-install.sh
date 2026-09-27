#!/bin/bash
# Edge-case tests for install.sh.
#
# Every case runs the real installer against a throwaway HOME and BIN_DIR, with
# --no-deps --no-models so nothing is downloaded and nothing outside the
# sandbox is touched. Assertions are on the files the installer leaves behind
# and on the text it prints.
#
# Each run uses a sanitised PATH. That matters: the developer running this
# suite has voxtype installed for real, and without isolation every case would
# stop at the "another voxtype shadows this one" check, which is correct
# behaviour but useless as a test.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d)"

BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Guard against this suite ever writing to the developer's real Hammerspoon
# config. An earlier draft called 'voxtype install-hammerspoon' without passing
# HOME, which rewrote ~/.hammerspoon/voxtype.lua with a sandboxed binary path
# baked in and silently broke the real hotkeys.
REAL_MODULE="$HOME/.hammerspoon/voxtype.lua"
real_module_stamp() {
    [ -f "$REAL_MODULE" ] && cksum "$REAL_MODULE" 2>/dev/null || echo "absent"
}
REAL_STAMP="$(real_module_stamp)"
check_no_leak() {
    local now; now="$(real_module_stamp)"
    if [ "$now" != "$REAL_STAMP" ]; then
        printf '\n\033[31mLEAK\033[0m this suite modified %s\n' "$REAL_MODULE" >&2
        printf '      restore it with: voxtype install-hammerspoon\n' >&2
    fi
}
trap 'rm -rf "$SANDBOX"; check_no_leak' EXIT

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }

# run <home> [args...] -> combined output in $OUT, exit code in $RC
# PATH_EXTRA is prepended to the sanitised PATH.
run() {
    local home="$1"; shift
    OUT=$(cd "$ROOT" && env \
        HOME="$home" \
        PATH="${PATH_EXTRA:-$BASE_PATH}" \
        VOXTYPE_HEADLESS=1 \
        VOXTYPE_BIN_DIR="$home/bin" \
        VOXTYPE_INSTALL_STATE="$home/state/install-state" \
        /bin/bash install.sh --no-deps --no-models "$@" 2>&1)
    RC=$?
}

# Same as run(), but from a shell without a tty on stdin, and with a hard
# timeout, to prove the installer never blocks waiting for a human.
run_piped() {
    local home="$1" secs="$2"; shift 2
    local log="$SANDBOX/piped.$$.log"
    rm -f "$log"
    (
        cd "$ROOT" || exit 1
        exec env \
            HOME="$home" \
            PATH="$BASE_PATH" \
            VOXTYPE_HEADLESS=1 \
            VOXTYPE_BIN_DIR="$home/bin" \
            VOXTYPE_INSTALL_STATE="$home/state/install-state" \
            /bin/bash install.sh --no-deps --no-models "$@" < /dev/null
    ) > "$log" 2>&1 &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local killer=$!
    wait "$pid" 2>/dev/null
    RC=$?
    kill "$killer" 2>/dev/null
    wait "$killer" 2>/dev/null
    OUT=$(cat "$log" 2>/dev/null)
}

fresh() { # fresh <name> -> echoes a new sandbox home
    local h="$SANDBOX/$1"
    rm -rf "$h"
    mkdir -p "$h"
    printf '%s' "$h"
}

foreign_voxtype() { # foreign_voxtype <dir>
    mkdir -p "$1"
    printf '#!/bin/bash\necho foreign\n' > "$1/voxtype"
    chmod +x "$1/voxtype"
}

contains() { case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1" "expected [$2] in output" ;; esac; }
lacks()    { case "$OUT" in *"$2"*) bad "$1" "did not expect [$2] in output" ;; *) ok "$1" ;; esac; }
file_has()  { if grep -q "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "[$2] not in $1"; fi; }
file_lacks(){ if grep -q "$2" "$1" 2>/dev/null; then bad "$3" "[$2] unexpectedly in $1"; else ok "$3"; fi; }
check_rc()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc=$2 got rc=$3"; fi; }

echo "install.sh edge cases"
echo

# ---------------------------------------------------------------- basics

echo "help and argument handling"
OUT=$(/bin/bash "$ROOT/install.sh" --help 2>&1); RC=$?
check_rc "--help exits 0" 0 "$RC"
contains "--help documents --force"    "--force"  "$OUT"
contains "--help documents re-run"     "re-run"   "$OUT"
OUT=$(/bin/bash "$ROOT/install.sh" --nonsense 2>&1); RC=$?
check_rc "unknown flag exits 2" 2 "$RC"
contains "unknown flag is named" "--nonsense" "$OUT"

echo
echo "dry run"
H=$(fresh dryrun)
run "$H" --dry-run
check_rc "dry run exits 0" 0 "$RC"
contains "dry run says so"           "dry run"               "$OUT"
contains "dry run claims nothing changed" "Nothing was installed" "$OUT"
if [ -e "$H/bin/voxtype" ]; then bad "dry run wrote no binary" "binary exists"; else ok "dry run wrote no binary"; fi
if [ -e "$H/.hammerspoon/voxtype.lua" ]; then bad "dry run wrote no module" "module exists"; else ok "dry run wrote no module"; fi
if [ -e "$H/.zshrc" ]; then bad "dry run wrote no shell config" "zshrc exists"; else ok "dry run wrote no shell config"; fi

# ---------------------------------------------------------------- init.lua

echo
echo "existing Hammerspoon config"

H=$(fresh empty_init)
mkdir -p "$H/.hammerspoon"; : > "$H/.hammerspoon/init.lua"
run "$H"
check_rc "empty init.lua: exits 0" 0 "$RC"
file_has "$H/.hammerspoon/init.lua" 'require("voxtype")' "empty init.lua gets the require"

H=$(fresh user_init)
mkdir -p "$H/.hammerspoon"
printf 'hs.alert.show("mine")\n' > "$H/.hammerspoon/init.lua"
run "$H"
file_has "$H/.hammerspoon/init.lua" 'hs.alert.show("mine")' "user config is preserved"
file_has "$H/.hammerspoon/init.lua" 'require("voxtype")'    "require is added"
if grep -q 'hs.alert.show("mine")' "$H/.hammerspoon/init.lua.voxtype-backup" 2>/dev/null; then
    ok "original is kept as a backup"
else
    bad "original is kept as a backup" "backup missing or wrong"
fi

echo
echo "re-running is idempotent"
H=$(fresh idem)
mkdir -p "$H/.hammerspoon"; printf -- '-- mine\n' > "$H/.hammerspoon/init.lua"
run "$H"; run "$H"; run "$H"
n=$(grep -c 'require("voxtype")' "$H/.hammerspoon/init.lua")
if [ "$n" = "1" ]; then ok "three runs leave exactly one require"; else bad "three runs leave exactly one require" "found $n"; fi
# The backup must stay the pristine original. A timestamped name here would let
# run 2 overwrite the pre-voxtype file with a voxtype-modified one.
if [ -f "$H/.hammerspoon/init.lua.voxtype-backup" ]; then
    ok "one backup of the original init.lua"
    file_has "$H/.hammerspoon/init.lua.voxtype-backup" '^-- mine$' "the backup is the untouched original"
    file_lacks "$H/.hammerspoon/init.lua.voxtype-backup" 'voxtype' "the backup was not overwritten by a later run"
else
    bad "one backup of the original init.lua" "no backup file"
fi
b=0
for f in "$H"/.hammerspoon/*; do
    case "${f##*/}" in *voxtype-backup*) b=$((b + 1)) ;; esac
done
if [ "$b" = "1" ]; then ok "re-runs do not pile up backups"; else bad "re-runs do not pile up backups" "found $b"; fi

echo
echo "init.lua that already loads voxtype"
H=$(fresh alt_require)
mkdir -p "$H/.hammerspoon"
printf 'require("voxtype")\nhs.alert.show("mine")\n' > "$H/.hammerspoon/init.lua"
run "$H"
n=$(grep -c 'require("voxtype")' "$H/.hammerspoon/init.lua")
if [ "$n" = "1" ]; then ok "an existing require is not duplicated"; else bad "an existing require is not duplicated" "found $n"; fi
file_has "$H/.hammerspoon/init.lua" 'hs.alert.show("mine")' "other config still there"

# ---------------------------------------------------------------- conflicts

echo
echo "conflicts are reported, not silently resolved"

H=$(fresh shadow)
foreign_voxtype "$H/other"
PATH_EXTRA="$H/other:$BASE_PATH" run "$H"; PATH_EXTRA=""
check_rc "shadowing install refuses" 1 "$RC"
contains "shadowing is explained"   "comes first on your PATH" "$OUT"
contains "shadowing offers removal" "rm -f"                    "$OUT"
contains "shadowing offers --force" "--force"                 "$OUT"
if [ -e "$H/bin/voxtype" ]; then bad "refused install wrote no binary" "binary exists"; else ok "refused install wrote no binary"; fi

echo
echo "--force overrides a PATH conflict"
H=$(fresh forced)
foreign_voxtype "$H/other"
PATH_EXTRA="$H/other:$BASE_PATH" run "$H" --force; PATH_EXTRA=""
check_rc "--force proceeds" 0 "$RC"
if [ -x "$H/bin/voxtype" ]; then ok "--force installed the binary"; else bad "--force installed the binary" "missing"; fi

echo
echo "an unrecognised binary in the way is backed up"
H=$(fresh alien)
mkdir -p "$H/bin"
printf '#!/bin/bash\necho "some other tool"\n' > "$H/bin/voxtype"; chmod +x "$H/bin/voxtype"
run "$H"
contains "alien binary is reported" "replaced an unrecognised" "$OUT"
if ls "$H"/bin/voxtype.voxtype-backup.* >/dev/null 2>&1; then
    ok "alien binary is kept as a backup"
else
    bad "alien binary is kept as a backup" "no backup file found"
fi
file_has "$H/bin/voxtype" "VOXTYPE_VERSION" "the real binary replaced the alien one"

echo
echo "our own binary is upgraded quietly, not treated as a conflict"
H=$(fresh upgrade)
run "$H"
if grep -q 'VOXTYPE_VERSION' "$H/bin/voxtype" 2>/dev/null; then
    OUT=$(/bin/bash "$H/bin/voxtype" version 2>&1); RC=$?
    check_rc "installed binary runs" 0 "$RC"
    contains "installed binary reports a version" "0." "$OUT"
else
    bad "installed binary runs" "no VOXTYPE_VERSION marker"
fi
b=$(ls -1 "$H"/bin/voxtype.voxtype-backup.* 2>/dev/null | wc -l | tr -d ' ')
if [ "$b" = "0" ]; then ok "upgrading our own binary makes no backup"; else bad "upgrading our own binary makes no backup" "found $b"; fi

# ---------------------------------------------------------------- ownership

echo
echo "uninstall only removes what the installer created"

H=$(fresh uninstall)
run "$H"
if [ -x "$H/bin/voxtype" ]; then ok "binary installed before uninstall"; else bad "binary installed before uninstall" "missing"; fi
run "$H" --uninstall
check_rc "uninstall exits 0" 0 "$RC"
if [ -e "$H/bin/voxtype" ]; then bad "uninstall removes the binary" "still there"; else ok "uninstall removes the binary"; fi
if [ -e "$H/.hammerspoon/voxtype.lua" ]; then bad "uninstall removes the module" "still there"; else ok "uninstall removes the module"; fi
contains "uninstall explains what it left" "left in place" "$OUT"

echo
echo "uninstall restores a user init.lua"
H=$(fresh restore)
mkdir -p "$H/.hammerspoon"; printf -- '-- my own config\nhs.alert.show("x")\n' > "$H/.hammerspoon/init.lua"
run "$H"
run "$H" --uninstall
if [ -f "$H/.hammerspoon/init.lua" ]; then
    file_has "$H/.hammerspoon/init.lua" 'hs.alert.show("x")' "original init.lua restored"
    file_lacks "$H/.hammerspoon/init.lua" 'require("voxtype")' "require removed on uninstall"
else
    bad "original init.lua restored" "init.lua is gone"
fi

echo
echo "uninstall removes an init.lua it created itself"
H=$(fresh selfcreated)
run "$H"
run "$H" --uninstall
if [ -e "$H/.hammerspoon/init.lua" ]; then bad "installer-created init.lua removed" "still there"; else ok "installer-created init.lua removed"; fi

echo
echo "login items"
H=$(fresh loginitem)
mkdir -p "$H/.hammerspoon" "$H/state"
printf 'require("voxtype")\n' > "$H/.hammerspoon/init.lua"
# Record that this login item predates us, then install and remove.
printf 'WE_MADE_LOGIN_ITEM=0\n' > "$H/state/install-state"
run "$H"
printf 'WE_MADE_LOGIN_ITEM=0\n' > "$H/state/install-state"
run "$H" --uninstall
contains "headless uninstall leaves login items alone" "left the login items alone" "$OUT"

echo
echo "a headless uninstall never edits login items"
H=$(fresh ourlogin)
mkdir -p "$H/.hammerspoon" "$H/state"
printf 'require("voxtype")\n' > "$H/.hammerspoon/init.lua"
printf 'WE_MADE_LOGIN_ITEM=1\n' > "$H/state/install-state"
run "$H" --uninstall
contains "headless uninstall reports it skipped login items" "left the login items alone" "$OUT"
contains "headless uninstall does not touch the running app" "did not touch the running Hammerspoon" "$OUT"

echo
echo "uninstall with nothing installed is harmless"
H=$(fresh bareuninstall)
run "$H" --uninstall
check_rc "uninstall on a clean home exits 0" 0 "$RC"

# ---------------------------------------------------------------- flags

echo
echo "flag combinations"
H=$(fresh nohs)
run "$H" --no-hammerspoon
check_rc "--no-hammerspoon exits 0" 0 "$RC"
contains "--no-hammerspoon explains why"  "hotkeys were not installed" "$OUT"
contains "--no-hammerspoon gives an alternative" "voxtype start"   "$OUT"
contains "--no-hammerspoon offers a later install" "install-hammerspoon" "$OUT"
if [ -e "$H/.hammerspoon/voxtype.lua" ]; then bad "--no-hammerspoon writes no module" "module exists"; else ok "--no-hammerspoon writes no module"; fi
if [ -x "$H/bin/voxtype" ]; then ok "--no-hammerspoon still installs the CLI"; else bad "--no-hammerspoon still installs the CLI" "missing"; fi

H=$(fresh missing_deps)
run "$H" --no-deps
contains "--no-deps warns about missing deps" "missing" "$OUT"
contains "--no-deps says how to fix it" "brew install" "$OUT"

H=$(fresh nomodels)
run "$H" --no-models
contains "--no-models says how to finish later" "voxtype warmup" "$OUT"

# --no-models must also skip the multi-GB ollama pull, not just the whisper warmup.
# A stub ollama records whether it was ever asked to pull.
echo
echo "--no-models skips the big ollama pull"
H=$(fresh nopull)
mkdir -p "$H/stub"
cat > "$H/stub/ollama" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        pull) echo "PULLED" >> "$VOXTYPE_TEST_OLLAMA_LOG"; exit 0 ;;
        list) echo "NAME"; exit 0 ;;
    esac
done
echo "ollama 0.0.0-stub"
STUB
chmod +x "$H/stub/ollama"
: > "$H/ollama.log"
OUT=$(cd "$ROOT" && env \
    HOME="$H" PATH="$H/stub:$BASE_PATH" VOXTYPE_HEADLESS=1 \
    VOXTYPE_TEST_OLLAMA_LOG="$H/ollama.log" \
    VOXTYPE_BIN_DIR="$H/bin" VOXTYPE_INSTALL_STATE="$H/state/install-state" \
    /bin/bash install.sh --no-deps --no-models 2>&1); RC=$?
check_rc "--no-models with a stub ollama exits 0" 0 "$RC"
if grep -q PULLED "$H/ollama.log" 2>/dev/null; then
    bad "--no-models never pulls a model" "the stub ollama was asked to pull"
else
    ok "--no-models never pulls a model"
fi
contains "--no-models says how to pull later" "ollama pull" "$OUT"

# ...and the same run with models enabled must actually pull.
H=$(fresh yespull)
mkdir -p "$H/stub"
cp "$H/../nopull/stub/ollama" "$H/stub/ollama"
: > "$H/ollama.log"
OUT=$(cd "$ROOT" && env \
    HOME="$H" PATH="$H/stub:$BASE_PATH" VOXTYPE_HEADLESS=1 \
    VOXTYPE_TEST_OLLAMA_LOG="$H/ollama.log" \
    VOXTYPE_BIN_DIR="$H/bin" VOXTYPE_INSTALL_STATE="$H/state/install-state" \
    /bin/bash install.sh --no-deps 2>&1); RC=$?
check_rc "model install with a stub ollama exits 0" 0 "$RC"
if grep -q PULLED "$H/ollama.log" 2>/dev/null; then
    ok "the default run does pull the rewrite model"
else
    bad "the default run does pull the rewrite model" "never asked to pull"
fi

# ---------------------------------------------------------------- non-interactive

echo
echo "non-interactive runs"
H=$(fresh yesflag)
run_piped "$H" 90 --yes
check_rc "--yes exits 0 on a pipe" 0 "$RC"
contains "--yes is reported" "assumed yes" "$OUT"

H=$(fresh noyes)
run_piped "$H" 90
check_rc "plain pipe does not hang" 0 "$RC"
if [ -x "$H/bin/voxtype" ]; then ok "plain pipe still installed the CLI"; else bad "plain pipe still installed the CLI" "missing"; fi

# ---------------------------------------------------------------- summary

echo
echo "the summary reports real changes"
H=$(fresh summary)
run "$H"
contains "summary has a what-changed section" "what changed"      "$OUT"
contains "summary lists the binary"          "bin/voxtype"        "$OUT"
contains "summary mentions the permissions"  "Privacy & Security" "$OUT"
contains "summary ends with the privacy note" "leaves"            "$OUT"
contains "summary shows the PATH change"     "to PATH"            "$OUT"

# ---------------------------------------------------------------- portability

echo
echo "bash 3.2 compatibility"
if /bin/bash -n "$ROOT/install.sh" 2>/dev/null; then ok "install.sh parses under bash 3.2"; else bad "install.sh parses under bash 3.2" "syntax error"; fi
SBX="$SANDBOX/compat"; mkdir -p "$SBX"
if env HOME="$SBX" VOXTYPE_INSTALL_STATE="$SBX/state/install-state" /bin/bash -c '
    set -uo pipefail
    . "'"$ROOT"'/scripts/lib/common.sh"
    . "'"$ROOT"'/scripts/preflight.sh"
    state_set K "v with spaces"
    [ "$(state_get K)" = "v with spaces" ] || exit 1
    [ "$(free_gb / | tr -d "." | wc -c)" -gt 3 ] || exit 1
    require_bash >/dev/null || exit 1
    require_macos >/dev/null || exit 1
    require_arch >/dev/null || exit 1
' 2>/dev/null; then ok "helpers work under bash 3.2"; else bad "helpers work under bash 3.2" "failed"; fi

echo
echo "preflight helpers"
SBX2="$SANDBOX/helpers"; mkdir -p "$SBX2"
if env HOME="$SBX2" VOXTYPE_INSTALL_STATE="$SBX2/state/install-state" /bin/bash -c '
    set -uo pipefail
    . "'"$ROOT"'/scripts/lib/common.sh"
    . "'"$ROOT"'/scripts/preflight.sh"
    require_not_root >/dev/null || exit 1
    net_ok https://api.github.com/ || exit 1
    path_matches definitely_not_a_real_program >/dev/null 2>&1 && exit 1
    [ -z "$(path_matches definitely_not_a_real_program)" ] || exit 1
    b=$(backup_file "'"$ROOT"'/bin/voxtype") || exit 1
    [ -f "$b" ] || exit 1
    rm -f "$b"
' 2>/dev/null; then ok "preflight helpers behave"; else bad "preflight helpers behave" "failed"; fi

echo
echo "the piped install path"
# This is the path every new user takes, and it is the one path the rest of this
# suite never runs: the script arrives on stdin, so it has no file to resolve a
# repo from and has to download the tree. It also runs before common.sh exists,
# so anything here that reaches for the library is a bug that only shows up in
# production. An earlier draft called have/info in this function, which made
# every piped install silently take the tarball path and print two errors.
#
# The stubs keep this offline and deterministic. curl only intercepts the
# codeload tarball URL and defers everything else to the real curl, so the
# network preflight still does its actual job.
make_stubs() { # make_stubs <home> <git: fail|work>
    local h="$1" mode="$2"
    mkdir -p "$h/stub" "$h/cwd" "$h/stage/smart-transcriber-1.0.0"
    # bsdtar has no --transform, so stage the tree under its archive root instead.
    cp -R "$ROOT/install.sh" "$ROOT/bin" "$ROOT/share" "$ROOT/scripts" \
        "$h/stage/smart-transcriber-1.0.0/" 2>/dev/null
    cat > "$h/stub/curl" <<STUB
#!/bin/bash
url=""; out=""; prev=""
for a in "\$@"; do
    case "\$prev" in -o) out="\$a" ;; esac
    case "\$a" in http*) url="\$a" ;; esac
    prev="\$a"
done
case "\$url" in
    *codeload.github.com*)
        [ -n "\$out" ] || exit 1
        tar -czf "\$out" -C "$h/stage" smart-transcriber-1.0.0 || exit 1
        exit 0 ;;
    *) exec /usr/bin/curl "\$@" ;;
esac
STUB
    if [ "$mode" = "work" ]; then
        cat > "$h/stub/git" <<STUB
#!/bin/bash
# Stand-in for 'git clone --depth 1 --branch <ref> <url> <dest>'
dest="\${@: -1}"
mkdir -p "\$dest" || exit 1
cp -R "$ROOT/install.sh" "$ROOT/bin" "$ROOT/share" "$ROOT/scripts" "\$dest/" || exit 1
exit 0
STUB
    else
        printf '#!/bin/bash\nexit 1\n' > "$h/stub/git"
    fi
    chmod +x "$h/stub/curl" "$h/stub/git"
}

piped_run() { # piped_run <home> [args...]
    local h="$1"; shift
    OUT=$(cd "$h/cwd" && env \
        HOME="$h" PATH="$h/stub:$BASE_PATH" VOXTYPE_HEADLESS=1 \
        VOXTYPE_BIN_DIR="$h/bin" VOXTYPE_INSTALL_STATE="$h/state/install-state" \
        /bin/bash -s -- --no-deps --no-models "$@" < "$ROOT/install.sh" 2>&1)
    RC=$?
}

H=$(fresh pipe_git); make_stubs "$H" work
piped_run "$H"
check_rc "piped install with git exits 0" 0 "$RC"
contains "piped install uses git when it works" "via git" "$OUT"
lacks    "piped git path is quiet about errors" "command not found"
if [ -x "$H/bin/voxtype" ]; then ok "piped git install produced a working binary"; else bad "piped git install produced a working binary" "missing"; fi
if [ -f "$H/.hammerspoon/voxtype.lua" ]; then ok "piped git install found share/hammerspoon.lua"; else bad "piped git install found share/hammerspoon.lua" "missing"; fi

H=$(fresh pipe_tar); make_stubs "$H" fail
piped_run "$H"
check_rc "piped install falls back to a tarball" 0 "$RC"
contains "the git failure is reported"   "did not work"       "$OUT"
contains "the tarball path is taken"      "downloading a tarball" "$OUT"
lacks    "piped tarball path is quiet about errors" "command not found"
if [ -x "$H/bin/voxtype" ]; then ok "piped tarball install produced a working binary"; else bad "piped tarball install produced a working binary" "missing"; fi
if [ -f "$H/.hammerspoon/voxtype.lua" ]; then ok "piped tarball install found share/hammerspoon.lua"; else bad "piped tarball install found share/hammerspoon.lua" "missing"; fi

echo
echo "a failed download is explained"
H=$(fresh pipe_nodl); make_stubs "$H" fail
printf '#!/bin/bash\nexit 1\n' > "$H/stub/curl"
piped_run "$H"
check_rc "an unreachable repo fails loudly" 1 "$RC"
contains "the failure names the repo"  "ompurwar/smart-transcriber" "$OUT"
contains "the failure suggests a ref"   "VOXTYPE_REF"              "$OUT"

echo
echo "a broken download is explained"
H=$(fresh pipe_bad); make_stubs "$H" fail
printf '#!/bin/bash\nexit 0\n' > "$H/stub/curl"
piped_run "$H"
check_rc "a corrupt tarball fails loudly" 1 "$RC"
contains "a corrupt tarball is reported" "could not download" "$OUT"

echo
echo "how the hotkeys get dropped"
# An earlier draft told the user to restart Hammerspoon but first tried
# osascript 'to reload', which Hammerspoon does not implement, so the line
# always failed silently and the hotkeys stayed live after an uninstall. The
# hs CLI cannot help either: it only reaches a running instance when hs.ipc is
# loaded, and this project cannot load it because an explicit require() of an
# extension hangs in Hammerspoon 1.1.1. So a restart is the answer, and the
# messages have to say that.
if grep -q "to reload" "$ROOT/install.sh"; then
    bad "no unsupported AppleScript reload" "install.sh still calls 'to reload'"
elif grep -q "restarting Hammerspoon" "$ROOT/install.sh"; then
    ok "no unsupported AppleScript reload"
else
    bad "no unsupported AppleScript reload" "the restart path is gone"
fi
if grep -q 'tell application "Hammerspoon" to quit' "$ROOT/install.sh"; then
    ok "the restart path quits Hammerspoon, which works"
else
    bad "the restart path quits Hammerspoon, which works" "no quit call found"
fi
H=$(fresh restart)
mkdir -p "$H/.hammerspoon" "$H/state"
printf 'require("voxtype")\n' > "$H/.hammerspoon/init.lua"
run "$H"
run "$H" --uninstall
contains "headless uninstall tells you to restart by hand" "restart Hammerspoon" "$OUT"

echo
echo "the hotkey marker cannot be stale"
# The wait loop trusts ~/.cache/voxtype/hs.log. A leftover 'hotkeys loaded' from
# a previous run makes a reinstall report success instantly while the hotkeys are
# still dead, which is exactly what a stale-marker check hides. The log has to be
# rotated before Hammerspoon is relaunched, keeping the old one as hs.log.1.
if grep -q 'hs.log.1' "$ROOT/scripts/setup-app.sh"; then
    ok "the marker log is rotated before relaunch"
else
    bad "the marker log is rotated before relaunch" "no rotation in setup-app.sh"
fi
# Order matters: rotate first, then relaunch, or the new run appends to the old
# log and the check is still meaningless.
rot=$(grep -n 'hs.log.1\|open -a Hammerspoon' "$ROOT/scripts/setup-app.sh" | head -2 | cut -d: -f1 | tr '\n' ' ')
set -- $rot
if [ "${1:-}" -lt "${2:-0}" ] 2>/dev/null; then
    ok "the log is rotated before Hammerspoon is relaunched"
else
    bad "the log is rotated before Hammerspoon is relaunched" "order is wrong: $rot"
fi

H=$(fresh marker)
mkdir -p "$H/.cache/voxtype"
printf 'pasted: old dictation\nhotkeys loaded 2020-01-01T00:00:00\n' > "$H/.cache/voxtype/hs.log"
printf 'require("voxtype")\n' > /dev/null
# Simulate the rotation the installer performs, then prove the old line is gone
# from the log the wait loop reads.
mv -f "$H/.cache/voxtype/hs.log" "$H/.cache/voxtype/hs.log.1"
if grep -q 'hotkeys loaded' "$H/.cache/voxtype/hs.log" 2>/dev/null; then
    bad "a stale marker cannot be read as a fresh load" "stale line still present"
else
    ok "a stale marker cannot be read as a fresh load"
fi
if grep -q 'hotkeys loaded' "$H/.cache/voxtype/hs.log.1"; then
    ok "the old log is kept for debugging"
else
    bad "the old log is kept for debugging" "hs.log.1 lost the history"
fi

echo
echo "the module is usable without the repo"
# The installer and the README both tell a user who skipped the hotkeys to run
# 'voxtype install-hammerspoon' later. That only works if the module was written
# to disk somewhere. It used to be read from $VOXTYPE_SHARE_DIR, which only the
# installer ever set, so the command died with an unbound variable.
H=$(fresh share)
run "$H"
if [ -f "$H/share/voxtype/hammerspoon.lua" ]; then
    ok "the module is installed next to the binary"
else
    bad "the module is installed next to the binary" "nothing under $H/share"
fi
# Remove what the installer already wrote, so the assertions below can only be
# satisfied by the standalone command itself.
rm -f "$H/.hammerspoon/voxtype.lua"
# HOME must be passed here. The command writes to $HOME/.hammerspoon, so calling
# it without HOME rewrites the developer's real Hammerspoon config and bakes a
# sandbox path into it.
OUT=$(env HOME="$H" "$H/bin/voxtype" install-hammerspoon 2>&1); RC=$?
check_rc "'voxtype install-hammerspoon' works on its own" 0 "$RC"
if [ -f "$H/.hammerspoon/voxtype.lua" ]; then
    ok "the standalone command wrote the hotkey module"
else
    bad "the standalone command wrote the hotkey module" "missing"
fi
# It must point at the binary it was installed alongside, not a fixed guess.
file_has "$H/.hammerspoon/voxtype.lua" "$H/bin/voxtype" "the module points at the installed binary"
lacks "the standalone command does not trip over an unset variable" "unbound variable"
lacks "the standalone command does not need VOXTYPE_SHARE_DIR" "VOXTYPE_SHARE_DIR"

# It must also work with no repo and no VOXTYPE_* env at all, which is how a
# user would actually type it.
rm -f "$H/.hammerspoon/voxtype.lua"
OUT=$(env HOME="$H" "$H/bin/voxtype" install-hammerspoon 2>&1); RC=$?
check_rc "it works with a bare environment" 0 "$RC"
if [ -f "$H/.hammerspoon/voxtype.lua" ]; then
    ok "a bare environment still writes the module"
else
    bad "a bare environment still writes the module" "missing"
fi

echo
echo "uninstall takes the module with it"
H=$(fresh unshshare)
run "$H"
run "$H" --uninstall
if [ -f "$H/share/voxtype/hammerspoon.lua" ]; then
    bad "uninstall removes the installed module" "still present"
else
    ok "uninstall removes the installed module"
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m%d passed, 0 failed\033[0m\n' "$pass"
    exit 0
else
    printf '\033[31m%d passed, %d failed\033[0m\n' "$pass" "$fail"
    exit 1
fi
