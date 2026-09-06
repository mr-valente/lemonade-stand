# Installed backends can change while a shell is open. This edits only PATH,
# never LD_LIBRARY_PATH or Python environments shared by unrelated backends.
backend-path
if status is-interactive
    function __lemonade_refresh_backend_path --on-event fish_prompt
        backend-path
    end
end
