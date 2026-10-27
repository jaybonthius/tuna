# Tuna shell integration for zsh: tells the terminal the folder (OSC 7),
# where prompts, input and commands start and how commands ended (OSC
# 133), and, when TUNA_SHELL_FEATURES names "title", the title (OSC 2):
# the folder at the prompt, the command while it runs.
#
# Tuna loads this by itself (the terminal-shell-integration setting). To
# load it yourself, for example in a shell started by `exec zsh`, add to
# ~/.zshrc:
#   [[ "$INSIDE_TUNA" = terminal ]] && source /path/to/tuna/plugins/terminal/shell/tuna.zsh
#
# Prompt marks: at each prompt, 133;D for the command before it (only
# after a 133;C), then 133;A, printed before the prompt, and PS1 wrapped
# in 133;P;k=i ... 133;B (its continuation rows in 133;P;k=s) and PS2 in
# 133;P;k=s ... 133;B, wrapped again every time because themes set PS1 in
# their own precmd. Ours runs last, so it wraps what they set. 133;C, with
# the command line, comes from preexec.

[[ -o interactive ]] || builtin return 0
(( ${+functions[_tuna_precmd]} )) && builtin return 0

builtin typeset -g _tuna_executing= _tuna_marked_ps1= _tuna_saved_ps1= _tuna_saved_ps2=

# REPLY: $1 percent-encoded, for 133;C's cmdline_url.
_tuna_urlencode() {
    builtin emulate -L zsh
    builtin local LC_ALL=C text=$1 out= c
    builtin integer i
    for (( i = 1; i <= ${#text}; i++ )); do
        c=${text[i]}
        case $c in
            ([a-zA-Z0-9.~_/-]) out+=$c ;;
            (*) builtin printf -v c '%%%02X' "'$c"; out+=$c ;;
        esac
    done
    REPLY=$out
}

# Put PS1 and PS2 back as the user set them, so commands never see the
# marks.
_tuna_restore_prompt() {
    if [[ -n $_tuna_marked_ps1 && $PS1 == $_tuna_marked_ps1 ]]; then
        PS1=$_tuna_saved_ps1
        PS2=$_tuna_saved_ps2
    fi
}

_tuna_precmd() {
    builtin local ret=$?
    _tuna_restore_prompt
    if [[ -n $_tuna_executing ]]; then
        builtin printf '\e]133;D;%s\a' $ret
    fi
    _tuna_executing=
    builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "$HOST" "$PWD"
    if [[ $TUNA_SHELL_FEATURES == *title* ]]; then
        builtin printf '\e]2;%s\a' "${(%):-%(4~|…/%3~|%~)}"
    fi
    _tuna_saved_ps1=$PS1
    _tuna_saved_ps2=$PS2
    builtin local initial=$'%{\e]133;P;k=i\a%}' secondary=$'%{\e]133;P;k=s\a%}' input=$'%{\e]133;B\a%}'
    PS1=${initial}${PS1//$'\n'/$'\n'${secondary}}${input}
    PS2=${secondary}${PS2}${input}
    _tuna_marked_ps1=$PS1
    builtin printf '\e]133;A;cl=line\a'
    # Stay the last precmd, so the marks wrap what other hooks set.
    if [[ ${precmd_functions[-1]} != _tuna_precmd ]]; then
        precmd_functions=(${precmd_functions:#_tuna_precmd} _tuna_precmd)
    fi
}

_tuna_preexec() {
    _tuna_restore_prompt
    if [[ $TUNA_SHELL_FEATURES == *title* ]]; then
        builtin printf '\e]2;%s\a' "${1//[[:cntrl:]]/}"
    fi
    _tuna_urlencode "$1"
    builtin printf '\e]133;C;cmdline_url=%s\a' "$REPLY"
    _tuna_executing=1
}

builtin typeset -ag precmd_functions preexec_functions
precmd_functions+=(_tuna_precmd)
preexec_functions+=(_tuna_preexec)
