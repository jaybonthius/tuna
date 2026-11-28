#!tuna
(import (languages) (modes) (prog) (hooks) (tables))

(tables:define-table keymap "Keys in CSS buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on css:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "CSS")
  (keymap keymap)
  (hook mode-hook))

(languages:define-grammar css
  (git "https://github.com/tree-sitter/tree-sitter-css" "dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f"))

(languages:define-language "css"
  (mode mode)
  (file-names "css")
  (grammar css)
  (block-comments ("/*" "*/"))
  (strings ("\"" "\"" (escape #\\) line-bound) ("'" "'" (escape #\\) line-bound))
  (brackets ("(" ")") ("[" "]") ("{" "}"))
  (symbol-characters "-_"))
