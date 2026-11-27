(import (options) (plugins))
(import (tuna)) ; spelling below
(use-plugin spell (git "https://github.com/bob/spell") ; bob's fork
  (commit "189d646")   ; pinned
  (config
    ;; British
    (options:set! spell:language "en-GB")
    (display (list 'config (spell:check "w")))
    (newline)))
(use-plugin dict (git "https://github.com/bob/dict") ; newest
  (config (display "[dict config]\n")))
(import (console))
