# PS1 is wrapped again at every prompt, since themes and .bashrc set it
# after this file loads. Bash before 4.4 has no PS0, so it gets no mark
# where a command starts.

[[ "$-" == *i* ]] || builtin return 0
[[ "$(builtin type -t __tuna_prompt_command)" = function ]] && builtin return 0

if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
    __tuna_host='\H'
    __tuna_host=${__tuna_host@P}
else
    __tuna_host=$HOSTNAME
fi

__tuna_urlencode() {
    builtin local LC_ALL=C text="$1" out= c i
    for ((i = 0; i < ${#text}; i++)); do
        c=${text:i:1}
        case $c in
            [a-zA-Z0-9.~_/-]) out+=$c ;;
            *) builtin printf -v c '%%%02X' "'$c"; out+=$c ;;
        esac
    done
    REPLY=$out
}

__tuna_prompt_shown=
__tuna_marked_ps1=

# Commands never see the marks.
__tuna_restore_prompt() {
    if [[ -n "$__tuna_marked_ps1" && "$PS1" == "$__tuna_marked_ps1" ]]; then
        PS1=$__tuna_saved_ps1
        PS2=$__tuna_saved_ps2
    fi
}

__tuna_keep_status() {
    __tuna_status=$?
    builtin return $__tuna_status
}

__tuna_prompt_command() {
    builtin local status=${__tuna_status:-0}
    __tuna_restore_prompt
    if [[ -n "$__tuna_prompt_shown" ]]; then
        builtin printf '\e]133;D;%s\a' "$status"
    fi
    __tuna_prompt_shown=1
    __tuna_urlencode "$PWD"
    builtin printf '\e]7;file://%s%s\a' "$__tuna_host" "$REPLY"
    __tuna_saved_ps1=$PS1
    __tuna_saved_ps2=$PS2
    builtin local secondary='\[\e]133;P;k=s\a\]' input='\[\e]133;B\a\]'
    PS1="\[\e]133;P;k=i\a\]${PS1}"
    [[ "$PS1" == *'\n'* ]] && PS1=${PS1//'\n'/'\n'"$secondary"}
    PS1+=$input
    PS2="${secondary}${PS2}${input}"
    __tuna_marked_ps1=$PS1
    builtin printf '\e]133;A;cl=line\a'
    builtin return $status
}

__tuna_preexec() {
    __tuna_restore_prompt
    builtin local command
    command=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1)
    command=${command#*[[:digit:]][* ] }
    __tuna_urlencode "$command"
    builtin printf '\e]133;C;cmdline_url=%s\a' "$REPLY"
}

if [[ "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    PROMPT_COMMAND=(__tuna_keep_status "${PROMPT_COMMAND[@]}" __tuna_prompt_command)
else
    PROMPT_COMMAND="__tuna_keep_status${PROMPT_COMMAND:+; $PROMPT_COMMAND}; __tuna_prompt_command"
fi

if ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3))); then
    # A function substitution runs in this shell, so it can restore PS1.
    PS0+='${ __tuna_preexec; }'
elif ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
    PS0+='$(__tuna_preexec >/dev/tty)'
fi
