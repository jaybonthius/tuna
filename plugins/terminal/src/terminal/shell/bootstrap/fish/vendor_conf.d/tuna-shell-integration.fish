# fish reads vendor configuration from each folder on XDG_DATA_DIRS, so
# this takes its own folder out again before the shell starts programs
# that would see it.

if set -q TUNA_SHELL_INTEGRATION_XDG_DIR
    if set -q XDG_DATA_DIRS
        set --function --path _tuna_xdg_dirs "$XDG_DATA_DIRS"
        if set --function index (contains --index "$TUNA_SHELL_INTEGRATION_XDG_DIR" $_tuna_xdg_dirs)
            set --erase --function _tuna_xdg_dirs[$index]
        end
        if set -q _tuna_xdg_dirs[1]
            set --global --export --unpath XDG_DATA_DIRS "$_tuna_xdg_dirs"
        else
            set --erase --global XDG_DATA_DIRS
        end
    end
    set --erase TUNA_SHELL_INTEGRATION_XDG_DIR
end

status --is-interactive; or exit 0

if set -q TUNA_SHELL_INTEGRATION_DIR; and test -r "$TUNA_SHELL_INTEGRATION_DIR/tuna.fish"
    source "$TUNA_SHELL_INTEGRATION_DIR/tuna.fish"
end
