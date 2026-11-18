# fish 4 marks prompts and commands itself (OSC 133, its mark-prompt
# feature); only older fish gets the marks here.

status --is-interactive; or return
functions -q __tuna_osc7; and return

function __tuna_osc7 --on-event fish_prompt
    printf '\e]7;file://%s%s\a' "$hostname" (string escape --style=url -- "$PWD")
end

if not status test-feature mark-prompt 2>/dev/null
    set -g __tuna_prompt_state ""

    # A command cancelled before fish_postexec still ends.
    function __tuna_mark_prompt_start --on-event fish_prompt --on-event fish_posterror
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
