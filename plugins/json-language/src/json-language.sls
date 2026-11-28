#!tuna
(import (languages) (modes) (prog) (hooks) (tables))

(tables:define-table keymap "Keys in JSON buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on json-language:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "JSON")
  (keymap keymap)
  (hook mode-hook))

(tables:define-table jsonc-keymap "Keys in buffers of JSON with comments.")

(hooks:define-hook jsonc-mode-hook "Called in each buffer that turns on json-language:jsonc-mode.")

(modes:define-major-mode jsonc-mode
  (parent mode)
  (lighter "JSONC")
  (keymap jsonc-keymap)
  (hook jsonc-mode-hook))

(languages:define-grammar json
  (git "https://github.com/tree-sitter/tree-sitter-json" "254c42a6476413b776221e03982ac8ae159eeb72"))

(languages:define-language "json"
  (mode mode)
  (file-names "json" "geojson" "webmanifest" ".prettierrc" ".babelrc")
  (grammar json)
  (strings ("\"" "\"" (escape #\\) line-bound))
  (brackets ("{" "}") ("[" "]")))

(languages:define-language "jsonc"
  (mode jsonc-mode)
  (file-names "jsonc" "tsconfig.json" "jsconfig.json" ".eslintrc.json" "devcontainer.json")
  (grammar json)
  (line-comments ("//"))
  (block-comments ("/*" "*/"))
  (strings ("\"" "\"" (escape #\\) line-bound))
  (brackets ("{" "}") ("[" "]")))
