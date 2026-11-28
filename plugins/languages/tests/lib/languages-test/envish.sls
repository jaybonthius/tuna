#!tuna
(import (languages) (modes) (languages-test shellish) (hooks) (tables))

(tables:define-table keymap "Keys.")
(hooks:define-hook mode-hook "Setup.")
(modes:define-major-mode mode (keymap keymap) (hook mode-hook))

(languages:define-language "envish"
  (mode mode)
  (file-names ".envish" ".envish.*")
  (grammar languages-test/shellish:shellish))
