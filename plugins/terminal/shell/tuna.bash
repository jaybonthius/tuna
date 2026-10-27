# Tuna shell integration for bash: tells the terminal the folder (OSC 7),
# where prompts, input and commands start and how commands ended (OSC
# 133), and, when TUNA_SHELL_FEATURES names "title", the title (OSC 2):
# the folder at the prompt, the command while it runs.
#
# Tuna loads this by itself (the terminal-shell-integration setting). To
# load it yourself, for example in a shell started by `exec bash`, add to
# ~/.bashrc:
#   [[ "$INSIDE_TUNA" = terminal ]] && source /path/to/tuna/plugins/terminal/shell/tuna.bash
#
# Prompt marks: 133;A once per prompt, printed before the prompt; PS1 is
# wrapped in 133;P;k=i ... 133;B (its \n continuation rows in 133;P;k=s)
# and PS2 in 133;P;k=s ... 133;B, wrapped again at every prompt because
# themes and .bashrc set PS1 after this file loads. 133;C comes from PS0,
# once per command line, with the command line; 133;D with the status at
# the next prompt. Bash 4.4 or later has PS0; older bash gets no 133;C.

# Only interactive shells, and only once.
[[ "$-" == *i* ]] || builtin return 0
[[ "$(builtin type -t __tuna_prompt_command)" = function ]] && builtin return 0

if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
    # gethostname(2), as Tuna compares it, without forking.
    __tuna_host='\H'
    __tuna_host=${__tuna_host@P}
else
    __tuna_host=$HOSTNAME
fi

__tuna_osc7() {
    builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "$__tuna_host" "$PWD"
}

# REPLY: $1 percent-encoded, for 133;C's cmdline_url.
__tuna_urlencode() {
    builtin local LC_ALL=C text=$1 out= c i
    for ((i = 0; i < ${#text}; i++)); do
        c=${text:i:1}
        case $c in
            [a-zA-Z0-9.~_/-]) out+=$c ;;
            *) builtin printf -v c '%%%02X' "'$c"; out+=$c ;;
        esac
    done
    REPLY=$out
}

__tuna_title() {
    [[ "$TUNA_SHELL_FEATURES" == *title* ]]
}

__tuna_prompt_shown=
__tuna_marked_ps1=

# Put PS1 and PS2 back as the user set them, so commands never see the
# marks.
__tuna_restore_prompt() {
    if [[ -n "$__tuna_marked_ps1" && "$PS1" == "$__tuna_marked_ps1" ]]; then
        PS1=$__tuna_saved_ps1
        PS2=$__tuna_saved_ps2
    fi
}

# First in PROMPT_COMMAND: keep the command's status, and give it back to
# the user's prompt commands.
__tuna_keep_status() {
    __tuna_status=$?
    builtin return $__tuna_status
}

# Last in PROMPT_COMMAND, after the user's prompt commands and themes have
# set PS1 and perhaps reported a folder of their own.
__tuna_prompt_command() {
    builtin local status=${__tuna_status:-0}
    __tuna_restore_prompt
    # The previous command ended (none before the first prompt).
    if [[ -n "$__tuna_prompt_shown" ]]; then
        builtin printf '\e]133;D;%s\a' "$status"
    fi
    __tuna_prompt_shown=1
    __tuna_osc7
    __tuna_saved_ps1=$PS1
    __tuna_saved_ps2=$PS2
    builtin local initial='\[\e]133;P;k=i\a\]' secondary='\[\e]133;P;k=s\a\]' input='\[\e]133;B\a\]'
    PS1="${initial}${PS1}"
    # Each row of a prompt after a \n escape is a continuation of it.
    [[ "$PS1" == *'\n'* ]] && PS1=${PS1//'\n'/'\n'"$secondary"}
    __tuna_title && PS1+='\[\e]2;\w\a\]'
    PS1+=$input
    PS2="${secondary}${PS2}${input}"
    __tuna_marked_ps1=$PS1
    builtin printf '\e]133;A;redraw=last;cl=line;aid=%s\a' "${BASHPID:-$$}"
    builtin return $status
}

# From PS0, after a command line is read and before it runs.
__tuna_preexec() {
    __tuna_restore_prompt
    builtin local command
    command=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1)
    command=${command#*[[:digit:]][* ] }
    if __tuna_title && [[ -n "$command" ]]; then
        builtin printf '\e]2;%s\a' "${command//[[:cntrl:]]/}"
    fi
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
