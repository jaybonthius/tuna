#!tuna
(import (languages) (modes) (prog) (hooks) (tables))

(tables:define-table keymap "Keys in YAML buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on yaml:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "YAML")
  (keymap keymap)
  (hook mode-hook))

(languages:define-grammar yaml
  (git "https://github.com/tree-sitter-grammars/tree-sitter-yaml" "a1c4812a73ec5e089de8e441fdea3a921e8d5079"))

(languages:define-language "yaml"
  (mode mode)
  (file-names "yml" "yaml" ".clang-format" ".clang-tidy")
  (grammar yaml)
  (line-comments ("#" word-start))
  (strings ("\"" "\"" (escape #\\)) ("'" "'" word-start))
  (brackets ("[" "]") ("{" "}")))
