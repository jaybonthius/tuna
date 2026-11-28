#!tuna
(import (languages) (modes) (prog) (sh-script) (hooks) (tables))

(tables:define-table keymap "Keys in .env buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on dotenv:mode.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Env")
  (keymap keymap)
  (hook mode-hook))

(languages:define-language "dotenv"
  (mode mode)
  (file-names ".env" ".env.*")
  (grammar sh-script:bash)
  (line-comments ("#" word-start))
  (strings ("\"" "\"" (escape #\\)) ("'" "'"))
  (symbol-characters "_"))
