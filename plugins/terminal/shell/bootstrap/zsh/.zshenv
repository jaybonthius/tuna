# zsh reads ZDOTDIR's .zshenv first, so this gives the user's ZDOTDIR
# back, reads their .zshenv, and loads the integration once .zshrc has
# set the prompts.

if [[ -n "${TUNA_ZSH_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$TUNA_ZSH_ZDOTDIR"
    'builtin' 'unset' 'TUNA_ZSH_ZDOTDIR'
else
    'builtin' 'unset' 'ZDOTDIR'
fi

{
    'builtin' 'typeset' _tuna_file=${ZDOTDIR-$HOME}"/.zshenv"
    [[ ! -r "$_tuna_file" ]] || 'builtin' 'source' '--' "$_tuna_file"
} always {
    if [[ -o 'interactive' && -r "$TUNA_SHELL_INTEGRATION_DIR/tuna.zsh" ]]; then
        'builtin' 'source' '--' "$TUNA_SHELL_INTEGRATION_DIR/tuna.zsh"
    fi
    'builtin' 'unset' '_tuna_file'
}
