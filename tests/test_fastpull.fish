#!/usr/bin/env fish
# An interactive fish config can define its own `path` helper, which shadows the
# `path` builtin these functions rely on. Drop it so the tests exercise the real
# code rather than the surrounding shell.
functions -e path

set -l repo (builtin path resolve (builtin path dirname (status filename))/..)
source "$repo/functions/fastpull.fish"
set -l failures 0
set -l sandbox (mktemp -d)

function fail --argument-names message
    echo "FAIL: $message" >&2
    set -g failures (math $failures + 1)
end
set -g failures 0

# --- cache root resolution -------------------------------------------------
set -gx HF_HUB_CACHE "$sandbox/hub"
if test (__fastpull_hub) != "$sandbox/hub"
    fail 'HF_HUB_CACHE must win when it is set.'
end
set -e HF_HUB_CACHE
set -gx HF_HOME "$sandbox/home"
if test (__fastpull_hub) != "$sandbox/home/hub"
    fail 'HF_HOME must supply the hub directory when HF_HUB_CACHE is unset.'
end
set -e HF_HOME
if test (__fastpull_hub) != /huggingface/hub
    fail 'the container default hub path must be the last resort.'
end

# --- snapshot path construction --------------------------------------------
set -gx HF_HUB_CACHE "$sandbox/hub"
set -l got (__fastpull_snapshot_dir owner/repo abc123)
if test "$got" != "$sandbox/hub/models--owner--repo/snapshots/abc123"
    fail "snapshot dir must flatten the repo id; got '$got'"
end
# A repo id with several segments still flattens on every separator.
set got (__fastpull_snapshot_dir a/b/c deadbeef)
if test "$got" != "$sandbox/hub/models--a--b--c/snapshots/deadbeef"
    fail "every '/' must be flattened; got '$got'"
end
if __fastpull_snapshot_dir '' abc123 >/dev/null 2>&1
    fail 'an empty repo id must not yield a snapshot path.'
end
if __fastpull_snapshot_dir owner/repo '' >/dev/null 2>&1
    fail 'an empty revision must not yield a snapshot path.'
end

# --- the guard that keeps writes inside the hub ----------------------------
# An unresolved snapshot path would otherwise make "$snapdir/$name" absolute and
# drop a multi-gigabyte file at the filesystem root.
if __fastpull_fetch_one '' '' some-model.gguf 100 '' 8 >/dev/null 2>&1
    fail 'fetch must refuse a repo/revision it could not resolve.'
end
if __fastpull_fetch_one owner/repo abc123 '' 100 '' 8 >/dev/null 2>&1
    fail 'fetch must refuse an empty file name.'
end
if test -e /some-model.gguf
    fail 'fetch wrote outside the hub.'
end

# --- present-file short circuit --------------------------------------------
set -l snapdir (__fastpull_snapshot_dir owner/repo abc123)
mkdir -p "$snapdir"
printf '0123456789' >"$snapdir/small.bin"
if not __fastpull_fetch_one owner/repo abc123 small.bin 10 '' 8 >/dev/null 2>&1
    fail 'a file already at the advertised size must be accepted without a fetch.'
end
# A size mismatch must not be treated as present; with no network here the fetch
# is expected to fail, but it must not silently claim success.
if __fastpull_fetch_one owner/repo abc123 small.bin 999 '' 8 >/dev/null 2>&1
    fail 'a size mismatch must not count as present.'
end

set -e HF_HUB_CACHE
rm -rf -- "$sandbox"

if test $failures -gt 0
    exit 1
end
echo 'All fastpull tests passed.'
