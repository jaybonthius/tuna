# Tuna's automatic shell integration for bash. Tuna starts bash with
# --posix and ENV naming this file, which a POSIX-mode interactive bash
# reads instead of its startup files. This file leaves POSIX mode, reads
# the startup files bash would have read, then loads ../../tuna.bash.

[[ "$-" == *i* ]] || builtin return 0

if [[ -n "$TUNA_BASH_INJECT" ]]; then
    builtin declare __tuna_bash_flags="$TUNA_BASH_INJECT"
    builtin unset ENV TUNA_BASH_INJECT
    # Give back an ENV the injection replaced.
    if [[ -n "$TUNA_BASH_ENV" ]]; then
        builtin export ENV=$TUNA_BASH_ENV
        builtin unset TUNA_BASH_ENV
    fi

    builtin set +o posix
    builtin shopt -u inherit_errexit 2>/dev/null
    # In POSIX mode HISTFILE defaults to ~/.sh_history; Tuna set bash's
    # own, which need not be exported.
    if [[ -n "$TUNA_BASH_UNEXPORT_HISTFILE" ]]; then
        builtin export -n HISTFILE
        builtin unset TUNA_BASH_UNEXPORT_HISTFILE
    fi

    # The startup files, as bash(1)'s INVOCATION reads them.
    if builtin shopt -q login_shell; then
        if [[ "$__tuna_bash_flags" != *--noprofile* ]]; then
            [[ -r /etc/profile ]] && builtin source /etc/profile
            for __tuna_rcfile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                [[ -r "$__tuna_rcfile" ]] && { builtin source "$__tuna_rcfile"; break; }
            done
        fi
    elif [[ "$__tuna_bash_flags" != *--norc* ]]; then
        for __tuna_rcfile in /etc/bash.bashrc /etc/bash/bashrc /etc/bashrc; do
            [[ -r "$__tuna_rcfile" ]] && { builtin source "$__tuna_rcfile"; break; }
        done
        [[ -r "$HOME/.bashrc" ]] && builtin source "$HOME/.bashrc"
    fi
    builtin unset __tuna_rcfile __tuna_bash_flags
fi

if [[ -n "$TUNA_SHELL_INTEGRATION_DIR" && -r "$TUNA_SHELL_INTEGRATION_DIR/tuna.bash" ]]; then
    builtin source "$TUNA_SHELL_INTEGRATION_DIR/tuna.bash"
fi
