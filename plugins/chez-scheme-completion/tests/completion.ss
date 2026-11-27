(import (tuna) (test) (test-runner) (test-user) (hooks) (commands) (keys) (buffers) (document) (views) (modes) (layout) (editing)
        (files) (prog) (minibuffer) (completion) (layout-float) (completion-popup) (completion-annotations)
        (chez-scheme) (chez-scheme-completion) (chez-scheme-test scheme-buffers))

;; Loaded, not imported, so the test's unload of it stays an unload.
(chez-scheme-test/scheme-buffers:write-lib-modules!)
(load-module! '(zeppo))

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define (show! b)
  (views:set-buffer! (view) b)
  (views:set-point! (view) (- (document:length (buffers:document b)) 1))
  b)

;; Highlighting finds a buffer's scope in a job, so a test waits until
;; the buffer's names have come.
(define (wait-for-names b)
  (test-runner:wait-until (lambda () (not (eq? (chez-scheme:names b) (chez-scheme:repl-names))))))

(define (session) (views:call-with-view (view) completion:current-session))

(define (rows)
  (let* ([s (session)] [ms (completion:session-matches s)])
    (map (lambda (k)
           (let ([m (completion:matches-ref ms k)])
             (list (completion:text s m) (completion:value s m) (completion:category s m)
                   (map (lambda (c) (if (pair? c) (cdr c) c)) (completion:annotation s m)))))
         (iota (completion:matches-count ms)))))

(define (texts) (map car (rows)))

(define (complete! typed)
  (test-user:type! typed)
  (test-user:press! "C-M-i")
  (test-runner:wait-until (lambda () (let ([s (session)]) (and s (not (completion:session-busy? s)))))))

(define (quit!) (test-user:press! "C-g"))

(define plugins (string-append (path-parent (car (command-line))) "/plugins"))

(define bs (files:visit (string-append plugins "/buffers/src/buffers.sls")))

(define zp (files:visit (string-append (getenv "HOME") "/.config/tuna/lib/zeppo.sls")))

(test-user:show! "|")

(test "C-M-i completes a name in a module's own file as the file spells it, valued by its export, with its kind; a plain library's name is an identifier"
  (show! bs)
  (wait-for-names bs)
  (complete! "\nins")
  (check-equal? '("insert!" buffers:insert! completion:name-category ("procedure")) (assoc "insert!" (rows)))
  (quit!)
  (complete! " document:tex")
  (check-equal? '(("document:text" "document:text" completion:identifier-category ("procedure"))
                  ("document:text-position" "document:text-position" completion:identifier-category ("procedure")))
                (rows))
  (quit!))

(test "RET inserts the spelling"
  (complete! " insert")
  (test-user:press! "M-n RET")
  (let ([t (text bs)]) (check-equal? " insert!" (substring t (- (string-length t) 8) (string-length t)))))

(test "a module's file sees a name help describes, such as spawn-task"
  (show! zp)
  (wait-for-names zp)
  (complete! "\nspawn")
  (check-equal? '("spawn-task" spawn-task completion:name-category ("procedure")) (assoc "spawn-task" (rows)))
  (quit!))

(test "in a helper's own module the helper completes, valued by its export"
  (complete! "\n%tu")
  (check-equal? '(("%tune" zeppo:%tune completion:name-category ("procedure"))) (rows))
  (quit!))

(test "a quoted name completes, and after ,@ the @ is no part of the name"
  (complete! "\n'vol")
  (check-equal? '("volume") (texts))
  (quit!)
  (complete! "\n`(,@vol")
  (check-equal? '("volume") (texts))
  (quit!))

(define user (buffers:make "user.ss" "(import (buffers) (zeppo))\n"))

(modes:set-major-mode chez-scheme:mode user)

(test "a buffer that imports a module completes its names as it spells them"
  (show! user)
  (wait-for-names user)
  (complete! "(buffers:ins")
  (check-equal? '("buffers:insert!" buffers:insert! completion:name-category ("procedure")) (assoc "buffers:insert!" (rows)))
  (quit!))

(test "at a call's head only procedures and syntax are offered; elsewhere, and after a square bracket, variables too"
  (complete! " (zeppo:")
  (check-equal? '("zeppo:sing" "zeppo:%tune") (texts))
  (quit!)
  (complete! " zeppo:")
  (check-equal? '("zeppo:sing" "zeppo:%tune" "zeppo:volume") (texts))
  (quit!)
  (complete! " [zeppo:")
  (check-equal? '("zeppo:sing" "zeppo:%tune" "zeppo:volume") (texts))
  (quit!))

(test "once an import unloads, the buffer's names lose its names; loaded again, they come back"
  (unload-owner! (module-owner '(zeppo)))
  (test-user:settle)
  (check-equal? #f (chez-scheme:find-name user 'zeppo:sing))
  (complete! " zeppo:")
  (check-equal? '() (texts))
  (quit!))

(load-module! '(zeppo))

(test "a module loaded again gives its names back"
  (test-runner:wait-until (lambda () (chez-scheme:find-name user 'zeppo:sing)))
  (check-equal? 'zeppo:sing (chez-scheme:name-export (chez-scheme:find-name user 'zeppo:sing))))

(test "in a configuration, a loaded plugin's helper completes, though no use-plugin line names it"
  (let ([config (buffers:make "init.ss" "(use-plugin buffers)\n")])
    (modes:set-major-mode chez-scheme:mode config)
    (show! config)
    (wait-for-names config)
    (complete! "(set! zeppo:%tu")
    (check-equal? '("zeppo:%tune") (texts))
    (quit!)))

(define read-outcome #f)

(commands:define-command (read-scheme) "Reads a line, keeping whether it was quit."
  (set! read-outcome 'waiting)
  (guard (c [(cancelled? c) (set! read-outcome 'quit)])
    (minibuffer:read "Eval: ")
    (set! read-outcome 'read)))

(keys:bind! keys:global "C-c r" read-scheme)

(test "a prompt has no Scheme scope of its own, so an entry that completes there offers the REPL's names"
  (define (prompt-names) (and (minibuffer:current-prompt) (chez-scheme-completion:name-region)))
  (hooks:add! completion:find-region prompt-names)
  (test-user:press! "C-c r")
  (complete! "(buffers:inser")
  (check-equal? '("buffers:insert!") (texts))
  (complete! " (zeppo:%tu")
  (check-equal? '(("zeppo:%tune" zeppo:%tune completion:name-category ("procedure"))) (rows))
  (test-user:press! "SPC")
  (check-equal? (list #f "(buffers:inser (zeppo:%tu ") (list (session) (minibuffer:input (minibuffer:current-prompt))))
  (quit!)
  (check-equal? 'quit read-outcome)
  (hooks:remove! completion:find-region prompt-names))

(define (target-at b spelling-end)
  (show! b)
  (views:set-point! (view) spelling-end)
  (chez-scheme-completion:name-target (view)))

(define (end-of b word)
  (let* ([t (text b)] [n (string-length word)])
    (let loop ([i 0])
      (if (string=? (substring t i (+ i n)) word)
          (document:position (buffers:document b) (+ i n) (document:unit characters))
          (loop (+ i 1))))))

(test "a target for a Tuna name is in the name category, valued by its export and with its spelling as text"
  (let ([t (target-at bs (end-of bs "(define (insert!"))])
    (check-equal? (list completion:name-category 'buffers:insert! "insert!")
                  (list (completion:target-category t) (completion:target-value t) (completion:target-text t)))))

(test "a plain library's name, or a name the buffer does not have, gives no target"
  (check-equal? #f (target-at bs (end-of bs "document:text")))
  (check-equal? #f (target-at user (end-of user "(import"))))

(test "a buffer with no Scheme scope gets the REPL's names, but a program in another language has no Scheme names"
  (let ([prose (buffers:make "prose" "see buffers:insert! here\n")])
    (check-equal? 'buffers:insert! (completion:target-value (target-at prose (end-of prose "buffers:insert!")))))
  (let ([python (buffers:make "program.py" "buffers:insert!\n")])
    (modes:set-major-mode prog:mode python)
    (check-equal? #f (target-at python (end-of python "buffers:insert!")))))
