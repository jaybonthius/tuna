(import (tuna) (caught-reports))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin files)
(use-plugin chez-scheme)
(use-plugin chez-scheme-completion)
(use-plugin eval)

(define (flag? name) (file-exists? (string-append (getenv "HOME") "/" name)))

(when (flag? "fail") (car 1))

(when (flag? "warn") (warning 'init "only a warning"))

(define after-fail 'ran)
