#!tuna
(import (languages) (modes) (prog) (hooks) (tables))

(tables:define-table keymap "Keys in shell script buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on sh-script:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Shell")
  (keymap keymap)
  (hook mode-hook))

(languages:define-grammar bash
  (git "https://github.com/tree-sitter/tree-sitter-bash" "a06c2e4415e9bc0346c6b86d401879ffb44058f7"))

(languages:define-language "shellscript"
  (mode mode)
  (file-names "sh" "bash" "zsh" "ksh" ".bashrc" ".bash_profile" ".bash_logout" ".profile" ".zshrc" ".zshenv" ".zprofile"
              ".envrc" "PKGBUILD")
  (interpreters "sh" "bash" "dash" "zsh" "ksh")
  (grammar bash)
  (line-comments ("#" word-start))
  (strings ("\"" "\"" (escape #\\)) ("'" "'"))
  (brackets ("(" ")") ("[" "]") ("{" "}"))
  (symbol-characters "_-."))
