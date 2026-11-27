(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (timers) (commands) (keys) (buffers) (views)
        (layout) (layout-split) (editing) (docs-at-point))

(options:set! docs-at-point:delay 0.05)

(define shown '())

(hooks:add! docs-at-point:displays
  (lambda (view docs asked?)
    (set! shown (cons (list view (map docs-at-point:doc-text docs) asked?) shown))))

(define (displayed)
  (let ([s (reverse shown)])
    (set! shown '())
    s))

(define (wait-for-display) (test-runner:wait-until (lambda () (pair? shown))))

;; The claims are that nothing is asked after a command, so the check
;; waits well past docs-at-point:delay first.
(define (past-delay) (timers:sleep 0.3))

(define (view) (layout:selected-view))

(define asked '())

(define (at-point v)
  (set! asked (cons v asked))
  (docs-at-point:make-doc (format "at ~a" (views:point v))))

(define (asked!)
  (let ([a asked])
    (set! asked '())
    a))

;; A source that pauses until the test lets it answer, so the order in
;; which entries answer is the test's.
(define held '())

(define (hold!) (suspend (lambda (resume) (set! held (cons resume held)))))

(define (release!)
  (test-runner:wait-until (lambda () (pair? held)))
  (let ([resumes held])
    (set! held '())
    (for-each (lambda (resume) (resume void)) resumes)))

(define slow-answer "slow")

(define slow-answered? #f)

(define (slow v)
  (set! slow-answered? #f)
  (hold!)
  (set! slow-answered? #t)
  (and slow-answer (docs-at-point:make-doc slow-answer)))

(define (fast v) (docs-at-point:make-doc "fast"))

(commands:define-command (stay) "Changes nothing." (void))

(keys:bind! keys:global "<f5>" stay)

(test-user:show! "|one two\nthree\n")

(test "after a command, once Tuna has been idle the delay, the sources are asked with the selected view, and the displays get it, its docs, and that the user did not ask"
  (hooks:add! docs-at-point:sources at-point)
  (test-user:press! "C-f")
  (wait-for-display)
  (check-equal? (list (view)) (asked!))
  (check-equal? (list (list (view) '("at 2") #f)) (displayed))
  (test-user:press! "C-f")
  (wait-for-display)
  (check-equal? (list (view)) (asked!))
  (check-equal? (list (list (view) '("at 3") #f)) (displayed)))

(test "a command that leaves the place as it was asks nothing again"
  (test-user:press! "<f5>")
  (past-delay)
  (check-equal? '() (asked!))
  (check-equal? '() (displayed)))

(test "with docs-at-point:after-edits-only?, a motion asks nothing and a typed character does"
  (options:set! docs-at-point:after-edits-only? #t)
  (test-user:press! "C-f")
  (past-delay)
  (check-equal? '(() ()) (list (asked!) (displayed)))
  (test-user:type! "x")
  (wait-for-display)
  (check-equal? (list (view)) (asked!))
  (check-equal? (list (list (view) '("at 5") #f)) (displayed))
  (options:unset! docs-at-point:after-edits-only?))

(test "docs-at-point:delay is read in the selected view's buffer"
  (buffers:with-buffer (views:buffer (view)) (options:set-local! docs-at-point:delay 60))
  (test-user:press! "C-b")
  (past-delay)
  (check-equal? '(() ()) (list (asked!) (displayed)))
  (buffers:with-buffer (views:buffer (view)) (options:unset-local! docs-at-point:delay))
  (test-user:press! "C-b")
  (wait-for-display)
  (check-equal? (list (list (view) '("at 3") #f)) (displayed))
  (asked!))

(test "with the mode off nothing is asked after a command; docs-at-point:ask-sources still asks, and says the user asked"
  (options:set! docs-at-point:mode #f)
  (test-user:press! "C-b")
  (past-delay)
  (check-equal? '(() ()) (list (asked!) (displayed)))
  (docs-at-point:ask-sources (view))
  (wait-for-display)
  (check-equal? (list (view)) (asked!))
  (check-equal? (list (list (view) '("at 2") #t)) (displayed))
  (options:unset! docs-at-point:mode))

(test "when no source applies any more in the buffer last asked about, the displays get no docs"
  (hooks:remove! docs-at-point:sources at-point)
  (test-user:press! "C-f")
  (wait-for-display)
  (check-equal? (list (list (view) '() #f)) (displayed))
  (asked!))

(test "under docs-at-point:first, a fast entry after a slow one waits for it, and shows once the slow one answers none"
  (hooks:add! docs-at-point:sources slow -1)
  (hooks:add! docs-at-point:sources fast)
  (docs-at-point:ask-sources (view))
  (test-user:settle)
  (check-equal? '() (displayed))
  (release!)
  (wait-for-display)
  (check-equal? (list (list (view) '("slow") #t)) (displayed))
  (set! slow-answer #f)
  (docs-at-point:ask-sources (view))
  (test-user:settle)
  (check-equal? '() (displayed))
  (release!)
  (wait-for-display)
  (check-equal? (list (list (view) '("fast") #t)) (displayed))
  (set! slow-answer "slow"))

(test "under docs-at-point:all, a slow entry holds back no fast one, and each change of the choice shows, in the order of the entries"
  (options:set! docs-at-point:strategy docs-at-point:all)
  (docs-at-point:ask-sources (view))
  (wait-for-display)
  (check-equal? (list (list (view) '("fast") #t)) (displayed))
  (release!)
  (wait-for-display)
  (check-equal? (list (list (view) '("slow" "fast") #t)) (displayed)))

(test "an answer that comes after point has moved is ignored"
  (docs-at-point:ask-sources (view))
  (wait-for-display)
  (check-equal? (list (list (view) '("fast") #t)) (displayed))
  (views:set-point! (view) (+ (views:point (view)) 1))
  (release!)
  (test-runner:wait-until (lambda () slow-answered?))
  (test-user:settle)
  (check-equal? '() (displayed)))

(test "a newer ask quits the task still answering an older one"
  (let ([quit? #f])
    (define (noting-quit v)
      (guard (c [(cancelled? c) (set! quit? #t) (raise c)])
        (hold!)
        #f))
    (hooks:remove! docs-at-point:sources slow)
    (hooks:add! docs-at-point:sources noting-quit -1)
    (docs-at-point:ask-sources (view))
    (test-runner:wait-until (lambda () (pair? held)))
    (set! held '())
    (docs-at-point:ask-sources (view))
    (test-runner:wait-until (lambda () quit?))
    (release!)
    (hooks:remove! docs-at-point:sources noting-quit)
    (displayed)))

(test "an entry that raises, or returns what is not a doc, a list of docs or #f, is reported, and the others' docs show"
  (define (broken v) (car '()))
  (define (odd v) 5)
  (hooks:add! docs-at-point:sources broken -2)
  (hooks:add! docs-at-point:sources odd -1)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (docs-at-point:ask-sources (view))
    (wait-for-display)
    (test-runner:wait-until (lambda () (= 2 (length reported))))
    (advice-remove! report keep)
    (check-equal? '(car docs-at-point:sources) (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                                                          (map condition-who reported))))
  (check-equal? (list (list (view) '("fast") #t)) (displayed))
  (hooks:remove! docs-at-point:sources broken)
  (hooks:remove! docs-at-point:sources odd))

(test "the displays get the view the sources were asked about, which need not be the selected one"
  (let ([other (layout-split:split-view! (view) (layout-split:direction row))])
    (docs-at-point:ask-sources other)
    (wait-for-display)
    (check-equal? (list (list other '("fast") #t)) (displayed))
    (check (not (eq? other (view))))))

(test "within one ask, a choice equal to the last does not call the displays again"
  (let ([steady (docs-at-point:make-doc "steady")])
    (define (first-answer v) steady)
    (define (later-none v) (hold!) #f)
    (hooks:remove! docs-at-point:sources fast)
    (hooks:add! docs-at-point:sources first-answer -1)
    (hooks:add! docs-at-point:sources later-none)
    (docs-at-point:ask-sources (view))
    (wait-for-display)
    (release!)
    (test-user:settle)
    (check-equal? (list (list (view) '("steady") #t)) (displayed))
    (hooks:remove! docs-at-point:sources first-answer)
    (hooks:remove! docs-at-point:sources later-none)))

(test "docs-at-point:strategy is read in the view's buffer, so a local value applies in one buffer"
  (options:unset! docs-at-point:strategy)
  (hooks:add! docs-at-point:sources fast)
  (hooks:add! docs-at-point:sources at-point 1)
  (buffers:with-buffer (views:buffer (view)) (options:set-local! docs-at-point:strategy docs-at-point:all))
  (docs-at-point:ask-sources (view))
  (test-runner:wait-until (lambda () (exists (lambda (s) (= 2 (length (cadr s)))) shown)))
  (check-equal? (list (view) (list "fast" (format "at ~a" (views:point (view)))) #t) (car (last-pair (displayed))))
  (buffers:with-buffer (views:buffer (view)) (options:unset-local! docs-at-point:strategy))
  (docs-at-point:ask-sources (view))
  (wait-for-display)
  (check-equal? (list (list (view) '("fast") #t)) (displayed))
  (hooks:remove! docs-at-point:sources at-point)
  (asked!))

(test "in an internal buffer only a source added in that buffer applies"
  (let ([prompt (buffers:make " *prompt*" "(car x)")] [local (lambda (v) (docs-at-point:make-doc "local"))])
    (views:set-buffer! (view) prompt)
    (docs-at-point:ask-sources (view))
    (wait-for-display)
    (check-equal? (list (list (view) '() #t)) (displayed))
    (buffers:with-buffer prompt (hooks:add-local! docs-at-point:sources local))
    (docs-at-point:ask-sources (view))
    (wait-for-display)
    (check-equal? (list (list (view) '("local") #t)) (displayed))))
