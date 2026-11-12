(import (tuna) (tuna plugins) (tuna eval)) ; spelling below
(use-plugin spell (git "https://github.com/bob/spell") ; bob's fork
  (commit "8a5b03d")   ; pinned
  (config
    ;; British
    (set-option! spell:language "en-GB")
    (display (list 'config (spell:check "w")))
    (newline)))
(use-plugin dict (git "https://github.com/bob/dict") ; newest
  (config (display "[dict config]\n")))
(import (console))
