#!tuna
(import (languages) (modes) (prog) (hooks) (tables))

(tables:define-table keymap "Keys in Python buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on python:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Python")
  (keymap keymap)
  (hook mode-hook))

(languages:define-grammar python
  (git "https://github.com/tree-sitter/tree-sitter-python" "293fdc02038ee2bf0e2e206711b69c90ac0d413f"))

(languages:define-language "python"
  (mode mode)
  (file-names "py" "pyi" "pyw" "SConstruct" "SConscript")
  (interpreters "python")
  (grammar python)
  (line-comments ("#"))
  (strings ("\"\"\"" "\"\"\"" (escape #\\))
           ("'''" "'''" (escape #\\))
           ("\"" "\"" (escape #\\) line-bound)
           ("'" "'" (escape #\\) line-bound))
  (brackets ("(" ")") ("[" "]") ("{" "}"))
  (word-characters "")
  (symbol-characters "_"))
