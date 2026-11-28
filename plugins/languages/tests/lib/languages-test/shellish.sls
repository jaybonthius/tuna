#!tuna
(import (languages) (modes) (hooks) (tables))

(tables:define-table keymap "Keys.")
(hooks:define-hook mode-hook "Setup.")
(modes:define-major-mode mode (keymap keymap) (hook mode-hook))

(languages:define-grammar shellish
  (git "https://example.org/tree-sitter-shellish" "0123456789abcdef0123456789abcdef01234567"))

(languages:define-language "shellish"
  (mode mode)
  (file-names "shellish" ".shellishrc")
  (interpreters "shellish")
  (grammar shellish)
  (line-comments ("#" word-start))
  (strings ("\"" "\"" (escape #\\)) ("'" "'"))
  (brackets ("(" ")") ("{" "}"))
  (symbol-characters "_-"))
