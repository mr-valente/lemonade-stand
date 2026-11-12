function versions --description 'Inventory Lemonade backend packages and ROCm runtimes'
    if test (count $argv) -gt 0
        if contains -- $argv[1] -h --help
            echo 'Usage: versions'
            echo 'Report local backend package markers, missing backends, and selected executable paths.'
            return 0
        end
        echo 'Usage: versions' >&2
        return 2
    end
    source (builtin path dirname (status filename))/backend-path.fish
    backend-path
    set -l root (__lemonade_backend_root)
    set -l families llamacpp llamacpp-hrx whispercpp sd-cpp flm kokoro vllm ryzenai-llm onnxruntime moonshine openmoss acestep thenoise thinksound trellis ds4 gufo halogen rocmfpx therock therock-wheels
    set -l catalogs /opt/share/lemonade-server/resources/backend_versions.json /usr/local/share/lemonade-server/resources/backend_versions.json /usr/share/lemonade-server/resources/backend_versions.json
    if set -q LEMONADE_BACKEND_VERSIONS_FILE
        set catalogs "$LEMONADE_BACKEND_VERSIONS_FILE"
    end
    for catalog in $catalogs
        test -f "$catalog"; or continue
        set -a families (jq -r 'to_entries[] | select(.value | type == "object") | .key | select(. != "checksums" and . != "rocm_asset_families")' "$catalog" 2>/dev/null)
        break
    end
    for directory in "$root"/*
        test -d "$directory"; or continue
        set -a families (builtin path basename "$directory")
    end
    printf 'Backend packages (%s)\n' "$root"
    echo 'Versions below are installed package markers, not upstream build numbers or running-process versions.'
    for family in (printf '%s\n' $families | sort -u)
        string match -qr '\.(old|staging)$' -- "$family"; and continue
        set -l directories
        for directory in "$root/$family"/*
            test -d "$directory"; or continue
            string match -qr '\.(old|staging)$' -- "$directory"; and continue
            set -a directories "$directory"
        end
        if test (count $directories) -eq 0
            printf '  %-30s not installed in managed cache\n' "$family"
            continue
        end
        for directory in $directories
            set -l label "$family/"(builtin path basename "$directory")
            set -l found false
            for marker in "$directory/version.txt" "$directory/versions.txt" "$directory/.info/version" "$directory/share/rocm/version"
                test -s "$marker"; or continue
                printf '  %s\n    source: %s\n' "$label" "$marker"
                while read -l line
                    test -n "$line"; and printf '    %s\n' "$line"
                end <"$marker"
                # A container backend's marker is its image pin; the image
                # itself lives on the Docker host and can be pruned there.
                set -l digest (string match -r 'sha256:[0-9a-f]{64}' <"$marker")[1]
                if test -n "$digest"
                    if not set -q images
                        # Images pulled by digest carry no tag, so Docker
                        # hides them unless asked for all images.
                        set -f images (command docker image ls -a -q 2>/dev/null | sort -u \
                            | xargs -r docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
                            | string replace -r '.*@' '')
                        command docker info >/dev/null 2>&1; or set -f images unreachable
                    end
                    if test "$images" = unreachable
                        echo '    image: Docker is not reachable, so its presence is unknown'
                    else if contains -- $digest $images
                        echo '    image: present on the Docker host'
                    else
                        printf '    image: missing from the Docker host; run: install %s %s\n' "$family" (builtin path basename "$directory")
                    end
                end
                set found true
            end
            if test "$found" = false
                printf '  %s: directory present; version unknown (no marker)\n    %s\n' "$label" "$directory"
            end
        end
    end
    echo
    echo 'Selected executables on PATH (may differ from a loaded model):'
    for binary in lemonade lemonade-server flm llama-server whisper-server sd-server vllm hipconfig rocminfo amd-smi rocm-smi rocm-sdk
        set -l executable (command -s "$binary")
        if test -n "$executable"
            printf '  %-18s %s\n' "$binary" "$executable"
            # Only query tools with a known version-only option. Package
            # markers above remain authoritative for managed releases.
            if contains -- "$binary" lemonade lemonade-server flm hipconfig; and command -q timeout
                set -l version_args --version
                test "$binary" = flm; and set version_args version --json
                set -l reported (command timeout 5 "$executable" $version_args 2>&1)
                if test $status -eq 0
                    for line in $reported
                        test -n "$line"; and printf '    CLI: %s\n' "$line"
                    end
                else
                    echo '    CLI version unavailable'
                end
            end
        else
            printf '  %-18s not on PATH\n' "$binary"
        end
    end
    echo
    echo 'ROCm runtime details:'
    source (builtin path dirname (status filename))/rocm-info.fish
    rocm-info
end
