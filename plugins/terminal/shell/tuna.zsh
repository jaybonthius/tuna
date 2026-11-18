# PS1 is wrapped again at every prompt, by a precmd kept last, since
# themes set it in their own precmd.

[[ -o interactive ]] || builtin return 0
(( ${+functions[_tuna_precmd]} )) && builtin return 0

builtin typeset -g _tuna_executing= _tuna_marked_ps1= _tuna_saved_ps1= _tuna_saved_ps2=

_tuna_urlencode() {
    builtin emulate -L zsh
    builtin local LC_ALL=C text="$1" out= c
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

# Commands never see the marks.
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
    _tuna_urlencode "$PWD"
    builtin printf '\e]7;file://%s%s\a' "$HOST" "$REPLY"
    _tuna_saved_ps1=$PS1
    _tuna_saved_ps2=$PS2
    builtin local secondary=$'%{\e]133;P;k=s\a%}' input=$'%{\e]133;B\a%}'
    PS1=$'%{\e]133;P;k=i\a%}'${PS1//$'\n'/$'\n'${secondary}}${input}
    PS2=${secondary}${PS2}${input}
    _tuna_marked_ps1=$PS1
    builtin printf '\e]133;A;cl=line\a'
    if [[ ${precmd_functions[-1]} != _tuna_precmd ]]; then
        precmd_functions=(${precmd_functions:#_tuna_precmd} _tuna_precmd)
    fi
}

_tuna_preexec() {
    _tuna_restore_prompt
    _tuna_urlencode "$1"
    builtin printf '\e]133;C;cmdline_url=%s\a' "$REPLY"
    _tuna_executing=1
}

builtin typeset -ag precmd_functions preexec_functions
precmd_functions+=(_tuna_precmd)
preexec_functions+=(_tuna_preexec)
