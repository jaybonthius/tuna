(import (tuna) (test) (test-user) (options) (tables) (commands) (keys) (buffers) (views) (layout) (ask) (diagnostics) (marks))

(define said '())

(options:set! ask:message-writer (lambda (text) (set! said (cons text said))))

(define (said!)
  (let ([s (reverse said)])
    (set! said '())
    s))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (map (lambda (c) (list (condition-who c) (condition-message c))) (reverse reported))))

(test-user:show! "|alpha beta gamma\ndelta epsilon\n\nzeta eta\n")

(define notes (views:buffer (layout:selected-view)))

(define (view) (layout:selected-view))

(define pressed '())

(define (pressed!)
  (let ([p (reverse pressed)])
    (set! pressed '())
    p))

(commands:define-command (on-own) "Notes a key in a diagnostic's own keymap." (set! pressed (cons 'own pressed)))

(commands:define-command (on-mark) "Notes a key in the mark keymap." (set! pressed (cons 'mark pressed)))

(commands:define-command (on-global) "Notes a global key." (set! pressed (cons 'global pressed)))

(tables:define-table own-keys)

(for-each
  (lambda (keymap command)
    (keys:bind! keymap "C-c a" command)
    (keys:bind! keymap "<mouse-1>" command))
  (list own-keys diagnostics:mark-keymap keys:global)
  (list on-own on-mark on-global))

(define source (diagnostics:make-source))

(define (at-word word) (+ (marks:word notes word) 1))

(marks:mode! notes #t)

(diagnostics:report! source notes
  (list (diagnostics:make-diagnostic (marks:word notes "beta") (+ (marks:word notes "beta") 4) (diagnostics:severity warning) "vague"
          (diagnostics:details [keymap own-keys]))
        (diagnostics:make-diagnostic (marks:word notes "delta") (+ (marks:word notes "delta") 5) (diagnostics:severity error) "wrong")
        (diagnostics:make-diagnostic (marks:word notes "zeta") (+ (marks:word notes "zeta") 4) (diagnostics:severity info) "short")))

(test "a diagnostic's own keymap answers a key at the cursor and a click before diagnostics:mark-keymap; without one the mark keymap answers"
  (check (eq? own-keys (diagnostics:diagnostic-keymap (car (diagnostics:in notes (at-word "beta"))))))
  (for-each
    (lambda (at) (views:set-point! (view) at) (test-user:press! "C-c a"))
    (list (at-word "beta") (at-word "delta") 1))
  (check-equal? '(own mark global) (pressed!))
  (test-user:settle)
  (test-user:click! (view) (at-word "beta"))
  (test-user:click! (view) (at-word "delta"))
  (check-equal? '(own mark) (pressed!)))

(test "with the mode off neither keymap applies"
  (marks:mode! notes #f)
  (views:set-point! (view) (at-word "beta"))
  (test-user:press! "C-c a")
  (test-user:settle)
  (test-user:click! (view) (at-word "delta"))
  (check-equal? '(global global) (pressed!))
  (marks:mode! notes #t))

(keys:bind! keys:global "M-n" diagnostics:next)

(keys:bind! keys:global "M-p" diagnostics:previous)

(define (at) (map marks:seen (diagnostics:in notes (views:point (view)))))

(test "next and previous go to the start of the Nth diagnostic after or before point, round the buffer's ends, and tell its text"
  (views:set-point! (view) 1)
  (said!)
  (test-user:press! "M-n")
  (check-equal? '((("beta" warning "vague")) ("vague")) (list (at) (said!)))
  (check-equal? (marks:word notes "beta") (views:point (view)))
  (test-user:press! "M-n M-n")
  (check-equal? '((("zeta" info "short")) ("wrong" "short")) (list (at) (said!)))
  (test-user:press! "M-n")
  (check-equal? '(("beta" warning "vague")) (at))
  (test-user:press! "M-p")
  (check-equal? '(("zeta" info "short")) (at))
  (views:set-point! (view) 1)
  (test-user:press! "M-2 M-n")
  (check-equal? '(("delta" error "wrong")) (at)))

(test "a negative count moves backward"
  (test-user:press! "M-- M-n")
  (check-equal? '(("beta" warning "vague")) (at)))

(test "C-u alone moves by one and skips infos and hints"
  (test-user:press! "C-u M-n")
  (check-equal? '(("delta" error "wrong")) (at))
  (test-user:press! "C-u M-p")
  (check-equal? '(("beta" warning "vague")) (at)))

(test "without wrap-around? it stops at the ends"
  (options:set! diagnostics:wrap-around? #f)
  (views:set-point! (view) (marks:word notes "zeta"))
  (check-equal? '((diagnostics:next "No more diagnostics")) (reports-during (lambda () (test-user:press! "M-n"))))
  (check-equal? '((diagnostics:previous "No more diagnostics")) (reports-during (lambda () (test-user:press! "M-p M-p M-p"))))
  (check-equal? '(("beta" warning "vague")) (at))
  (options:unset! diagnostics:wrap-around?))

(test "every diagnostic at the place reached is told, one per line"
  (diagnostics:report! source notes
    (list (diagnostics:make-diagnostic (marks:word notes "beta") (+ (marks:word notes "beta") 4) (diagnostics:severity warning) "vague")
          (diagnostics:make-diagnostic (marks:word notes "beta") (+ (marks:word notes "beta") 4) (diagnostics:severity error) "unknown"
            (diagnostics:details [origin "lint"] [code "E2"]))
          (diagnostics:make-diagnostic (marks:word notes "zeta") (+ (marks:word notes "zeta") 4) (diagnostics:severity info) "short")))
  (views:set-point! (view) 1)
  (said!)
  (test-user:press! "M-n")
  (check-equal? (list (marks:word notes "beta") '("lint [E2]: unknown\nvague")) (list (views:point (view)) (said!))))

(test "any prefix that is not a number filters as C-u does and moves one; a number counts, unfiltered"
  (views:set-point! (view) 1)
  (test-user:press! "C-u C-u M-n")
  (check-equal? '(("beta" error "unknown") ("beta" warning "vague")) (at))
  (test-user:press! "C-u C-u M-n")
  (check-equal? '(("beta" error "unknown") ("beta" warning "vague")) (at))
  (views:set-point! (view) 1)
  (test-user:press! "C-u 3 M-n")
  (check-equal? '(("zeta" info "short")) (at))
  (options:set! diagnostics:wrap-around? #f)
  (check-equal? '((diagnostics:next "No more errors or warnings")) (reports-during (lambda () (test-user:press! "C-u M-n"))))
  (options:unset! diagnostics:wrap-around?))
