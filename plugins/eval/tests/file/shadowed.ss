(import (tuna) (test) (eval) (eval-test))

(test "an installed plugin's #!tuna file, when the user's lib/ holds a module of the same name, is no module"
  (eval-test:write-file! ".config/tuna/lib/shadow.sls" "#!tuna\n(define (x) 'lib)\n")
  (check-raises (lambda (c) (and (error? c) (eq? 'eval:eval-file (condition-who c))
                                 (equal? (list (eval-test:home-path ".local/share/tuna/plugins/shadow/src/shadow.sls") '(shadow)
                                               (eval-test:home-path ".config/tuna/lib/shadow.sls"))
                                         (condition-irritants c))))
    (eval:eval-file "~/.local/share/tuna/plugins/shadow/src/shadow.sls")))
