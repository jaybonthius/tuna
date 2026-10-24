# completion-list

Shows the candidates of a completion read in rows under the minibuffer, with the part that matched highlighted and annotations in columns. `C-n` and `C-p` move, `M-<` and `M->` go to the first and last, `RET` chooses, `TAB` copies the selected candidate into the prompt, `M-RET` takes exactly what you typed, and a click chooses a row. Turn it off and completion still works, without the list.

Setting: `completion-count`, how many rows show (default 10). Stylesheets: `(completion-list tokens)` and `(completion-list rules)`.

## Acknowledgements

Follows Vertico, by Daniel Mendler.
