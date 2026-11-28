#!tuna
(import (languages) (modes) (prog) (hooks) (tables))

(tables:define-table keymap "Keys in TOML buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on toml:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "TOML")
  (keymap keymap)
  (hook mode-hook))

(languages:define-grammar toml
  (git "https://github.com/tree-sitter-grammars/tree-sitter-toml" "64b56832c2cffe41758f28e05c756a3a98d16f41"))

(languages:define-language "toml"
  (mode mode)
  (file-names "toml" "Cargo.lock" "uv.lock" "poetry.lock" "Pipfile")
  (grammar toml)
  (line-comments ("#"))
  (strings ("\"\"\"" "\"\"\"" (escape #\\)) ("'''" "'''") ("\"" "\"" (escape #\\) line-bound) ("'" "'" line-bound))
  (brackets ("[" "]") ("{" "}")))
