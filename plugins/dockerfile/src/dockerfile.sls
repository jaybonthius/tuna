#!tuna
(import (languages) (modes) (prog) (hooks) (tables))

(tables:define-table keymap "Keys in Dockerfile buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on dockerfile:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Dockerfile")
  (keymap keymap)
  (hook mode-hook))

(languages:define-grammar dockerfile
  (git "https://github.com/camdencheek/tree-sitter-dockerfile" "971acdd908568b4531b0ba28a445bf0bb720aba5"))

(languages:define-language "dockerfile"
  (mode mode)
  (file-names "Dockerfile" "Containerfile" "Dockerfile.*" "Containerfile.*" "dockerfile")
  (grammar dockerfile)
  (line-comments ("#" word-start))
  (strings ("\"" "\"" (escape #\\)) ("'" "'"))
  (brackets ("[" "]")))
