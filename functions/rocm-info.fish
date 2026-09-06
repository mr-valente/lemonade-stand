function rocm-info --description 'Show installed ROCm runtimes and selected diagnostic binaries'
    source (builtin path dirname (status filename))/backend-path.fish
    backend-path
    set -l found false
    for root in (__lemonade_rocm_roots)
        set -l runtime_version unknown
        for marker in "$root/.info/version" "$root/share/rocm/version" "$root/version.txt"
            if test -f "$marker"
                set runtime_version (string trim -- (head -n 1 "$marker"))
                break
            end
        end
        printf 'ROCm %s: %s\n' "$runtime_version" "$root"
        set found true
    end
    set -l bundle (__lemonade_backend_root)/vllm/rocm/version.txt
    if test -f "$bundle"
        printf 'vLLM bundle: %s (%s)\n' (string trim -- (cat "$bundle")) (builtin path dirname "$bundle")
        set found true
    end
    if test "$found" = false
        echo 'No local ROCm runtime found.'
    end
    for tool in hipconfig rocminfo rocm-smi amd-smi rocm-sdk
        set -l binary (command -s "$tool")
        test -n "$binary"; and printf '%s: %s\n' "$tool" "$binary"
    end
    echo 'hipconfig --version reports the selected HIP version; rocminfo reports devices and HSA runtime information.'
end
