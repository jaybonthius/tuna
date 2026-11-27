(import (tuna) (test) (plugins))

(define (write-file! path text)
  (let make ([folder (path-parent path)])
    (unless (file-directory? folder) (make (path-parent folder)) (mkdir folder)))
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))

(define (install-local! name text)
  (let ([folder (format "~a/plugins/~a" (getenv "HOME") name)])
    (write-file! (format "~a/src/~a.sls" folder name) text)
    (plugins:install! `(use-plugin ,(string->symbol name) (local ,folder)))))

(install-local! "spell"
  "#!tuna\n(define (language) \"en\")\n(define (dictionary-path) (string-append \"/usr/share/dict/\" (language)))\n")
(install-local! "prog" "#!tuna\n(import (spell))\n(override-set! spell:language (lambda () \"prog\"))\n")
(install-local! "prog2" "#!tuna\n(import (spell) (groucho words))\n(override-set! spell:language (lambda () \"prog2\"))\n")

(import (spell) (saver))

(define first (make-owner '(changes first)))
(define second (make-owner '(changes second)))

(define (changes-of p) (map (lambda (c) (list (owner-name (car c)) (cadr c))) (definition-changes p)))

(define (announce save! path) (string-append "<" (save! path) ">"))

(test "a top-level definition of a module's name is the owner's override, and the highest-ranked override is in effect"
  (call-as-owner first (lambda () (eval '(define spell:dictionary-path (lambda () "/home/groucho/words")) (interaction-environment))))
  (check-equal? '(((changes first) override) ((spell) define)) (changes-of spell:dictionary-path))
  (call-as-owner second (lambda () (eval '(define spell:dictionary-path (lambda () "/usr/share/dict/words")) (interaction-environment))))
  (check-equal? "/usr/share/dict/words" (spell:dictionary-path)))

(test "an owner's second override replaces its first"
  (call-as-owner second (lambda () (eval '(define spell:dictionary-path (lambda () "/tmp/words")) (interaction-environment))))
  (check-equal? "/tmp/words" (spell:dictionary-path))
  (check-equal? '(((changes second) override) ((changes first) override) ((spell) define)) (changes-of spell:dictionary-path)))

(test "owner-changes lists an owner's changes, newest first"
  (call-as-owner second (lambda () (advice-add! saver:save! announce)))
  (check-equal? '(advice override) (map car (owner-changes second))))

(test "a module's change is its own, and a module first loaded later ranks above one it does not import"
  (import (groucho words))
  (load-module! '(prog))
  (check-equal? "prog" (spell:language))
  (check-equal? '(((prog) override) ((groucho words) override) ((spell) define)) (changes-of spell:language))
  (check-equal? '(override) (map car (owner-changes (module-owner '(prog))))))

(test "advice wraps the definition in effect, the highest-ranked outermost, and changes are listed newest first"
  (define (bracket save! path) (string-append "[" (save! path) "]"))
  (call-as-owner first (lambda () (advice-add! saver:save! announce)))
  (call-as-owner (module-owner '(spell)) (lambda () (advice-add! saver:save! bracket)))
  (check-equal? "<<[a]>>" (saver:save! "a"))
  (check-equal? '(((spell) advice) ((changes first) advice) ((changes second) advice) ((saver) define))
                (changes-of saver:save!)))

(test "in code run as a module, a top-level definition of its own name is its override, which its importer's outranks"
  (call-as-owner (module-owner '(spell)) (lambda () (eval '(define spell:language (lambda () "assigned")) (interaction-environment))))
  (check-equal? '(((spell) override) ((prog) override) ((groucho words) override) ((spell) define)) (changes-of spell:language))
  (check-equal? "prog" (spell:language)))

(test "call-as-owner refuses what is not an owner"
  (check-raises assertion-violation? (call-as-owner (module-owner '(nothere)) (lambda () 1))))

(test "only the main thread makes changes"
  (define (on-thread thunk)
    (let ([result #f])
      (join-task (fork-task (lambda (restore) (set! result (guard (c [#t (condition-message c)]) (thunk))))))
      result))
  (for-each
    (lambda (thunk) (check-equal? "only the main thread changes owners and modules" (on-thread thunk)))
    (list (lambda () (call-as-owner second (lambda () (eval '(define spell:language (lambda () "thread")) (interaction-environment)))))
          (lambda () (call-as-owner second (lambda () (advice-add! saver:save! announce))))
          (lambda () (call-as-owner second (lambda () (advice-remove! saver:save! announce))))))
  (check-equal? "prog" (spell:language)))

(test "a module of lib/ that a plugin's module imports ranks below its importer"
  (load-module! '(prog2))
  (check-equal? "prog2" (spell:language))
  (check-equal? '((prog2) (spell) (prog) (groucho words) (spell)) (map car (changes-of spell:language))))

(test "a module keeps its rank when it reloads, and when it loads again after an unload"
  (reload-modules! '((prog)))
  (check-equal? "prog2" (spell:language))
  (unload-owner! (module-owner '(prog)))
  (check-equal? "prog2" (spell:language))
  (load-module! '(prog))
  (check-equal? "prog2" (spell:language)))
