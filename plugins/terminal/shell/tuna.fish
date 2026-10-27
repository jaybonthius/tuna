# Tuna shell integration for fish: tells the terminal the folder (OSC 7)
# and, where fish does not already, where prompts and commands start and
# how commands ended (OSC 133). fish sets the title itself (fish_title).
#
# Tuna loads this by itself (the terminal-shell-integration setting). To
# load it yourself, add to ~/.config/fish/config.fish:
#   test "$INSIDE_TUNA" = terminal; and source /path/to/tuna/plugins/terminal/shell/tuna.fish

status --is-interactive; or return
functions -q __tuna_osc7; and return

function __tuna_osc7 --on-event fish_prompt
    printf '\e]7;file://%s%s\a' "$hostname" (string escape --style=url -- "$PWD")
end

# fish 4 marks prompts and commands itself (its mark-prompt feature, on
# by default), with the command line on 133;C. Older fish, or fish with
# the feature off, get these handlers instead.
if not status test-feature mark-prompt 2>/dev/null
    set -g __tuna_prompt_state ""

    function __tuna_mark_prompt_start --on-event fish_prompt --on-event fish_posterror
        # A command that never reached fish_postexec, such as one
        # cancelled, still ends.
        if test "$__tuna_prompt_state" = running
            printf '\e]133;D\a'
        end
        set -g __tuna_prompt_state prompt
        printf '\e]133;A\a'
    end

    function __tuna_mark_output_start --on-event fish_preexec
        set -g __tuna_prompt_state running
        printf '\e]133;C;cmdline_url=%s\a' (string escape --style=url -- "$argv")
    end

    function __tuna_mark_output_end --on-event fish_postexec
        set -l last $status
        set -g __tuna_prompt_state ended
        printf '\e]133;D;%s\a' $last
    end
end
