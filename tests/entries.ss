(import (tuna) (test) (hooks) (options) (tables) (entries target) (entries helper))

(define (shouted) (let ([names (getprop 'entries 'shouted '())]) (putprop 'entries 'shouted '()) (reverse names)))

(define (noted) (let ([values (getprop 'entries 'noted '())]) (putprop 'entries 'noted '()) (reverse values)))

(define (greet name)
  (entries/target:greeted name)
  (list (shouted) (entries/target:text name) (tables:ref entries/target:names 'harpo)))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (next-file-tick)
  (suspend (lambda (resume) (fork-task (lambda (restore) (sleep (make-time 'time-duration 10000000 0)) (resume void))))))

(define (write-module! name text)
  (next-file-tick)
  (call-with-output-file (string-append (getenv "HOME") "/.config/tuna/lib/" name ".sls")
    (lambda (p) (put-string p text))
    'replace))

(test "an entry, advice or table value stays hidden while any removal of it stands"
  (load-module! '(entries adder))
  (check-equal? '(("Harpo") "[Harpo]" "Harpo") (greet "Harpo"))
  (load-module! '(entries quiet1))
  (load-module! '(entries quiet2))
  (check-equal? '(() "Chico" #f) (greet "Chico"))
  (check-equal? '(removal) (map car (owner-changes (module-owner '(entries quiet2)))))
  (unload-owner! (module-owner '(entries quiet1)))
  (check-equal? '(() "Chico" #f) (greet "Chico"))
  (unload-owner! (module-owner '(entries quiet2)))
  (check-equal? '(("Zeppo") "[Zeppo]" "Harpo") (greet "Zeppo")))

(test "removing again what a module has removed records nothing more"
  (load-module! '(entries quiet1))
  (call-as-owner (module-owner '(entries quiet1))
    (lambda ()
      (hooks:remove! entries/target:greeted entries/helper:shout)
      (advice-remove! entries/target:text entries/helper:wrap)
      (tables:remove! entries/target:names 'harpo)))
  (check-equal? '(removal) (map car (owner-changes (module-owner '(entries quiet1)))))
  (unload-owner! (module-owner '(entries quiet1)))
  (unload-owner! (module-owner '(entries adder))))

(test "while its module is unloaded, a hook entry of its definition is skipped and left out of hooks:entries, and advice of it raises"
  (let ([o (make-owner '(entries user))])
    (call-as-owner o
      (lambda ()
        (hooks:add! entries/target:greeted entries/helper:shout)
        (advice-add! entries/target:text entries/helper:wrap)))
    (check-equal? '(("Harpo") "[Harpo]" "Harpo") (greet "Harpo"))
    (unload-owner! (module-owner '(entries helper)))
    (entries/target:greeted "Chico")
    (check-equal? '() (shouted))
    (check-raises unloaded? (entries/target:text "Chico"))
    (check-equal? 0 (length (hooks:entries entries/target:greeted)))
    (check-equal? '(advice) (map car (owner-changes o)))
    (check-equal? '(advice define) (map cadr (definition-changes entries/target:text)))
    (load-module! '(entries helper))
    (check-equal? 1 (length (hooks:entries entries/target:greeted)))
    (check-equal? '(("Zeppo") "[Zeppo]" "Harpo") (greet "Zeppo"))
    (unload-owner! o)))

(options:define-option level 1 fixnum? #f)

(test "so is an entry of a hook hooks:define-hook did not make"
  (let ([o (make-owner '(entries noter))])
    (call-as-owner o (lambda () (hooks:add! options:changed entries/helper:noted)))
    (call-as-owner o (lambda () (options:set! level 2)))
    (check-equal? '(2) (noted))
    (unload-owner! (module-owner '(entries helper)))
    (call-as-owner o (lambda () (options:set! level 3)))
    (check-equal? '() (noted))
    (load-module! '(entries helper))
    (call-as-owner o (lambda () (options:set! level 4)))
    (check-equal? '(4) (noted))
    (unload-owner! o)))

(test "a hook entry whose definition its loaded module no longer defines is reported, naming it"
  (let* ([o (make-owner '(entries stale))] [reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (call-as-owner o (lambda () (hooks:add! entries/target:greeted entries/helper:shout) (advice-add! report keep)))
    (write-module! "entries/helper" "#!tuna\n(define (wrap text name) (string-append \"[\" (text name) \"]\"))\n")
    (reload-modules! '((entries helper)))
    (entries/target:greeted "Gummo")
    (check-equal? 1 (length reported))
    (check-equal? 'entries/helper:shout (condition-who (car reported)))
    (unload-owner! o)))
