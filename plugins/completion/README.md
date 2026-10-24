# completion

Choosing from a list. A command calls `completing-read` (the contract) with candidates; the `completion` plugin keeps the running question (the session), matches what you type, sorts recent answers first and asks the minibuffer for the prompt. Showing the candidates is a separate slot (`completion-ui-service`), which `completion-list` fills by default.

The plugin also holds:

- `M-x` (`execute-extended-command`): choose a visible command and run it;
- two matching styles: `substring`, and `any-order`, the space-separated parts you type in any order, each as plain text or a regular expression;
- the command annotator: a command's key binding and the first line of its documentation beside it.

Settings: `completion-styles` (default `(substring)`; the starter uses `(any-order substring)`) and `completion-category-overrides`. Other plugins add styles with `context-define-completion-style!` and annotators with `context-define-annotator!`.

## Acknowledgements

The `any-order` style follows Orderless, by Omar Antolín Camarena; the command annotations follow Marginalia, by Omar Antolín Camarena and Daniel Mendler; and the list, in `completion-list`, follows Vertico, by Daniel Mendler.
