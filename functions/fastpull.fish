function __fastpull_usage
    echo "Usage:"
    echo "  fastpull <owner/repo[:variant]> [pull options]"
    echo ""
    echo "Pre-seeds the Hugging Face cache using parallel ranged downloads, then"
    echo "hands off to 'pull' for registration. Lemonade downloads each file over a"
    echo "single connection; Hugging Face shapes per-connection throughput, so"
    echo "splitting a file across several connections is substantially faster."
    echo ""
    echo "Options:"
    echo "  -j, --streams <n>   Connections per file (default \$LEMONADE_FASTPULL_STREAMS or 8)"
    echo "  -h, --help          Show this help"
    echo ""
    echo "All other options are passed through to 'pull' unchanged. Files are"
    echo "verified against the sha256 Hugging Face advertises, and again by"
    echo "Lemonade when it registers them, so a bad transfer cannot be registered."
    echo "Anything fastpull cannot pre-seed is left for 'pull' to download normally."
end

function __fastpull_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 8000
    end
end

function __fastpull_hf_curl
    set -l args -sS --fail --max-time 60
    if set -q HF_TOKEN; and test -n "$HF_TOKEN"
        set -a args -H "Authorization: Bearer $HF_TOKEN"
    end
    printf '%s\n' $args
end

function __fastpull_hub
    if set -q HF_HUB_CACHE; and test -n "$HF_HUB_CACHE"
        echo $HF_HUB_CACHE
    else if set -q HF_HOME; and test -n "$HF_HOME"
        echo "$HF_HOME/hub"
    else
        echo /huggingface/hub
    end
end

# Repo-relative file -> absolute path inside the snapshot Lemonade will use.
function __fastpull_snapshot_dir --argument-names repo sha
    set -l flat (string replace -a -- / -- "$repo")
    if test -z "$flat"; or test -z "$sha"
        return 1
    end
    echo (__fastpull_hub)"/models--$flat/snapshots/$sha"
end

# Fetch one file over $streams ranged connections, verifying size and sha256.
# Returns 1 on any failure, leaving no partial file behind.
function __fastpull_fetch_one --argument-names repo sha name size want streams
    set -l snapdir (__fastpull_snapshot_dir "$repo" "$sha")
    set -l url "https://huggingface.co/$repo/resolve/$sha/$name"
    set -l curl_args (__fastpull_hf_curl)

    # Never write outside the hub: an unresolved snapshot path would otherwise
    # turn "$snapdir/$name" into an absolute path at the filesystem root.
    set -l hub (__fastpull_hub)
    if test -z "$snapdir"; or not string match -q "$hub/*" -- "$snapdir"; or test -z "$name"
        echo "  Error: refusing to pre-seed $name outside $hub." >&2
        return 1
    end

    set -l target "$snapdir/$name"
    mkdir -p (dirname "$target")

    if test -f "$target"; and test (stat -c %s "$target") -eq "$size"
        echo "  present: $name"
        return 0
    end

    # The ranged path preallocates the file, so a dropped chunk leaves a hole
    # rather than a short file: only the sha256 can tell it from a good
    # transfer. Without one, take the single connection, whose exit status is
    # trustworthy. Files big enough to be worth splitting are LFS objects on
    # Hugging Face and always advertise a hash, so this rarely costs anything.
    if test "$size" -lt 33554432; or test -z "$want"; or test "$want" = null
        echo "  fetch:   $name"
        if not curl $curl_args -L -o "$target" "$url"
            rm -f "$target"
            return 1
        end
    else
        set -l total_mib (math -s0 "ceil($size / 1048576)")
        set -l chunk_mib (math -s0 "ceil($total_mib / $streams)")
        printf '  fetch:   %s (%s MiB, %d connections)\n' "$name" $total_mib $streams

        if not truncate -s "$size" "$target"
            return 1
        end

        # fish 4 refuses to background a begin/end block, so the pipeline itself
        # is backgrounded. Correctness rests on the size and sha256 checks below
        # rather than on per-job exit status, which fish's `wait` does not report.
        for c in (seq 0 (math $streams - 1))
            set -l start (math "$c * $chunk_mib * 1048576")
            test "$start" -ge "$size"; and break
            set -l stop (math "$start + $chunk_mib * 1048576 - 1")
            test "$stop" -ge "$size"; and set stop (math "$size - 1")
            set -l seek (math "$c * $chunk_mib")
            curl $curl_args -L -r "$start-$stop" "$url" \
                | dd of="$target" bs=1M seek=$seek conv=notrunc status=none &
        end
        wait
    end

    if test (stat -c %s "$target") -ne "$size"
        echo "  Error: $name is the wrong size after transfer; leaving it to pull." >&2
        rm -f "$target"
        return 1
    end

    if test -n "$want"; and test "$want" != null
        set -l got (sha256sum "$target" | string split ' ')[1]
        if test "$got" != "$want"
            echo "  Error: $name failed sha256; leaving it to pull." >&2
            rm -f "$target"
            return 1
        end
    end
    return 0
end

function fastpull --description "Pull a model with parallel Hugging Face downloads"
    argparse -i h/help 'j/streams=' -- $argv
    or return 1

    if set -q _flag_help
        __fastpull_usage
        return 0
    end

    for tool in curl jq dd truncate sha256sum
        if not command -q $tool
            echo "Error: fastpull requires '$tool'." >&2
            return 1
        end
    end

    set -l streams 8
    if set -q LEMONADE_FASTPULL_STREAMS; and test -n "$LEMONADE_FASTPULL_STREAMS"
        set streams $LEMONADE_FASTPULL_STREAMS
    end
    set -q _flag_streams; and set streams $_flag_streams[-1]
    if not string match -qr '^[0-9]+$' -- "$streams"; or test "$streams" -lt 1
        echo "Error: --streams must be a positive integer." >&2
        return 1
    end

    # $argv is now the pull invocation, minus fastpull's own flags.
    set -l spec
    for arg in $argv
        if not string match -q -- '-*' "$arg"
            set spec $arg
            break
        end
    end

    if test -z "$spec"
        __fastpull_usage
        return 1
    end

    # Only registry checkpoints can be pre-seeded; plain model names and
    # --repair-mtp are pull's business entirely.
    if not string match -qr '^[^/]+/[^/]+' -- "$spec"; or contains -- --repair-mtp $argv; or contains -- -r $argv
        pull $argv
        return $status
    end

    set -l checkpoint (string split -m 1 : -- "$spec")[1]
    set -l inline_variant (string split -m 1 : -- "$spec")[2]

    set -l encoded (printf '%s' "$checkpoint" | jq -sRr @uri)
    set -l variants (curl -sS --max-time 180 \
        "http://localhost:"(__fastpull_port)"/api/v1/pull/variants?checkpoint=$encoded" 2>/dev/null)

    if test -z "$variants"; or not printf '%s\n' "$variants" | jq -e '.variants' >/dev/null 2>&1
        echo "Note: could not inspect $checkpoint; falling back to pull." >&2
        pull $argv
        return $status
    end

    # Mirror pull's selection: explicit --quant, then :variant, then the first
    # (recommended) entry. A mismatch only costs speed -- pull still decides.
    set -l variant $inline_variant
    set -l qi (contains -i -- --quant $argv); or set qi (contains -i -- -q $argv)
    if test -n "$qi"; and test (count $argv) -gt $qi
        set variant $argv[(math $qi + 1)]
    end
    test -z "$variant"; and set variant (printf '%s\n' "$variants" | jq -r '.variants[0].name // empty')

    set -l files (printf '%s\n' "$variants" | jq -r --arg v "$variant" '
        (.variants[] | select((.name // "") | ascii_downcase == ($v | ascii_downcase)) | .files[]?) // empty')

    if test (count $files) -eq 0
        echo "Note: no files matched variant '$variant'; falling back to pull." >&2
        pull $argv
        return $status
    end

    # Companions, matching pull's defaults.
    if not contains -- --no-mmproj $argv
        set -l mm (contains -i -- --mmproj $argv)
        if test -n "$mm"; and test (count $argv) -gt $mm
            set -a files $argv[(math $mm + 1)]
        else
            set -l advertised (printf '%s\n' "$variants" | jq -r '.mmproj_files[0] // empty')
            test -n "$advertised"; and set -a files $advertised
        end
    end
    if not contains -- --no-draft $argv
        set -l df (contains -i -- --draft $argv)
        if test -n "$df"; and test (count $argv) -gt $df
            set -a files $argv[(math $df + 1)]
        else
            # Only pre-seed an unambiguous draft; pull prompts when there are several.
            set -l drafts (printf '%s\n' "$variants" | jq -r '.draft_files[]? // empty')
            test (count $drafts) -eq 1; and set -a files $drafts[1]
        end
    end

    set -l curl_args (__fastpull_hf_curl)
    set -l rev (curl $curl_args "https://huggingface.co/api/models/$checkpoint/revision/main" 2>/dev/null)
    set -l sha (printf '%s\n' "$rev" | jq -r '.sha // empty')
    set -l tree (curl $curl_args "https://huggingface.co/api/models/$checkpoint/tree/$sha?recursive=true" 2>/dev/null)

    if test -z "$sha"; or test -z "$tree"
        echo "Note: could not resolve $checkpoint on Hugging Face; falling back to pull." >&2
        pull $argv
        return $status
    end

    echo "Pre-seeding $checkpoint@"(string sub -l 12 -- $sha)" with $streams connections per file"

    for name in $files
        set -l size (printf '%s\n' "$tree" | jq -r --arg n "$name" \
            'map(select(.path == $n)) | .[0] | (.lfs.size // .size // 0)')
        set -l want (printf '%s\n' "$tree" | jq -r --arg n "$name" \
            'map(select(.path == $n)) | .[0] | (.lfs.oid // "")')

        if test -z "$size"; or test "$size" = null; or test "$size" -le 0
            echo "  skip:    $name (not listed upstream; pull will handle it)"
            continue
        end

        if not __fastpull_fetch_one "$checkpoint" "$sha" "$name" "$size" "$want" "$streams"
            echo "  Note: pre-seed failed for $name; pull will download it normally." >&2
        end
    end

    echo
    pull $argv
end
