# Tuna's automatic shell integration for fish. Tuna puts the folder above
# this one first in XDG_DATA_DIRS, so fish reads this file with its
# vendor configuration. It takes that folder out again, so programs the
# shell starts do not see it, then loads ../../../tuna.fish.

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
