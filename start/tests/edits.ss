(import (tuna) (test) (plugins) (fixtures) (remotes))

(define spell-commits (remotes:commits "spell"))
(define dict-commit (fixtures:commit! "dict" '(("src/dict.sls" . "#!tuna\n(define (words) '(\"a\" \"b\"))\n"))))

(define (configuration spell-commit spell-line-start dict-commit-clause)
  (string-append
    "(import (options) (plugins))\n"
    "(import (tuna) (fixtures)) ; spelling below\n"
    spell-line-start "(use-plugin spell (git \"" (remotes:url "spell") "\") ; bob's fork\n"
    "  (commit \"" spell-commit "\")   ; pinned\n"
    "  (config\n"
    "    ;; British\n"
    "    (options:set! spell:language \"en-GB\")\n"
    "    (fixtures:note! (list 'config (spell:dictionary-path)))))\n"
    "(use-plugin dict (git \"" (fixtures:remote-url "dict") "\")" dict-commit-clause " ; newest\n"
    "  (config (fixtures:note! 'dict-config)))\n"))

(fixtures:write-file! (fixtures:configuration-path) (configuration (fixtures:short (car spell-commits)) "" ""))
(plugins:load-configuration!)
(fixtures:take-notes!)

(test "update! writes only the commit into the line, replacing its commit or adding one after its source, and the configuration read again runs the config forms"
  (plugins:update! 'spell)
  (check-equal? '((config "/usr/share/hunspell/en-GB") dict-config) (fixtures:take-notes!))
  (plugins:update! 'dict)
  (check-equal? '((config "/usr/share/hunspell/en-GB") dict-config) (fixtures:take-notes!))
  (check-equal? (configuration (cadr spell-commits) "" (format " (commit ~s)" dict-commit))
    (fixtures:read-file (fixtures:configuration-path))))

(test "remove! comments out the line, its config forms with it"
  (plugins:remove! 'spell)
  (check-equal? '(dict-config) (fixtures:take-notes!))
  (check-equal? (configuration (cadr spell-commits) "#;" (format " (commit ~s)" dict-commit))
    (fixtures:read-file (fixtures:configuration-path)))
  (check-equal? '(dict) (plugins:installed)))

(test "the configuration read again runs neither a removed line nor its forms, and the plugin stays unloaded"
  (plugins:load-configuration!)
  (check-equal? '(dict-config) (fixtures:take-notes!))
  (check-equal? "module (spell) is unloaded" (fixtures:raised-message (lambda () (fixtures:at-repl '(spell:dictionary-path))))))
