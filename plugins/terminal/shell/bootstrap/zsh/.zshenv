# Tuna's automatic shell integration for zsh. Tuna starts zsh with ZDOTDIR
# naming this folder, so zsh reads this file first. It gives ZDOTDIR back,
# reads the user's own .zshenv, and, in an interactive shell, loads
# ../../tuna.zsh, which marks prompts from the first one on, after
# .zshrc has set them.

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
