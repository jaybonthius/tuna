#!tuna
(import (languages) (modes) (hooks) (tables))

(tables:define-table keymap "Keys.")
(hooks:define-hook hook "Setup.")

(modes:define-major-mode make (keymap keymap) (hook hook))
(modes:define-major-mode docker (keymap keymap) (hook hook))
(modes:define-major-mode dotenv (keymap keymap) (hook hook))
(modes:define-major-mode ssh (keymap keymap) (hook hook))
(modes:define-major-mode shell (keymap keymap) (hook hook))
(modes:define-major-mode devfile (keymap keymap) (hook hook))

(languages:define-language "makefile" (mode make) (file-names "Makefile" "makefile" "GNUmakefile" "mk"))
(languages:define-language "dockerfile" (mode docker) (file-names "Dockerfile" "Dockerfile.*" "Containerfile.*"))
(languages:define-language "dotenv" (mode dotenv) (file-names ".env" ".env.*"))
(languages:define-language "ssh-config" (mode ssh) (file-names ".ssh/config" "ssh_config.d/*"))
(languages:define-language "shellscript" (mode shell) (file-names "sh" "*.d/*") (interpreters "sh" "bash"))
(languages:define-language "devfile" (mode devfile) (file-names "*.dev" "devfile"))
