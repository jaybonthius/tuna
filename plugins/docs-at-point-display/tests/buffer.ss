(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (timers) (buffers) (document) (views) (modes)
        (layout) (layout-split) (editing) (faces) (echo-area) (markdown) (docs-at-point) (docs-at-point-display) (docs-at-point-display-test signatures))

(options:set! docs-at-point:delay 0.05)

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

;; The claims are that the docs do not change, so the check waits well
;; past docs-at-point:delay first.
(define (past-delay) (timers:sleep 0.3))

(define (docs) (buffers:find "*Docs*"))

(define (docs-text) (document:text (buffers:document (docs))))

(define (docs-text-is? text) (lambda () (and (docs) (equal? text (docs-text)))))

(define (docs-view) (car (views:showing (docs))))

(define (texts class) (map test-user:element-text (test-user:elements (test-user:screen) class)))

(test-user:show! "|alpha beta\ngamma\n")

(define notes-view (layout:selected-view))

(define other-view (layout-split:split-view! notes-view (layout-split:direction row)))

(test "g raises before any docs are shown"
  (check-raises (raised? 'docs-at-point-display:refresh "No docs to refresh") (docs-at-point-display:refresh)))

(test "C-h . asks now and writes *Docs*, each doc under its thing as a heading and its Markdown drawn, and shows it in another view, leaving the selected one selected"
  (hooks:add! docs-at-point:sources docs-at-point-display-test/signatures:signature)
  (hooks:add! docs-at-point:sources docs-at-point-display-test/signatures:described 1)
  (options:set! docs-at-point:strategy docs-at-point:all)
  (test-user:press! "C-h .")
  (test-runner:wait-until (docs-text-is? "alpha\n(alpha x)\nalpha\nTakes alpha.\n"))
  (test-user:settle)
  (check-equal? (list (docs) notes-view) (list (views:buffer other-view) (layout:selected-view)))
  (check-equal? docs-at-point-display:docs-mode (modes:major-mode (docs)))
  (check-equal? '("alpha" "alpha") (texts "markdown-heading"))
  (check-equal? '("2" "2") (map (lambda (e) (test-user:element-attribute e "aria-level"))
                                (test-user:elements (test-user:screen) "markdown-heading")))
  (check-equal? '("(alpha x)") (texts "markdown-code-block"))
  (check-equal? '("alpha") (texts "markdown-strong"))
  (check-equal? '("Takes alpha.") (texts "markdown-paragraph")))

(test "*Docs* keeps no undo history and refuses edits"
  (check (buffers:silent? (docs)))
  (check (buffers:refuses-text? (docs) 1 1)))

(test "while *Docs* exists it follows point in other views"
  (test-user:press! "M-f M-f")
  (test-runner:wait-until (docs-text-is? "beta\n(beta x)\nbeta\nTakes beta.\n"))
  (test-user:press! "C-a"))

(test "with the mode off nothing follows point, and g in *Docs* asks again for the view the docs are about, at its point now"
  (test-runner:wait-until (docs-text-is? "alpha\n(alpha x)\nalpha\nTakes alpha.\n"))
  (options:set! docs-at-point:mode #f)
  (test-user:press! "M-f M-f")
  (past-delay)
  (check-equal? "alpha\n(alpha x)\nalpha\nTakes alpha.\n" (docs-text))
  (layout:select! other-view)
  (test-user:press! "g")
  (test-runner:wait-until (docs-text-is? "beta\n(beta x)\nbeta\nTakes beta.\n")))

(test "C-h . in *Docs* asks again for the view its docs are about"
  (docs-at-point-display-test/signatures:asked!)
  (test-user:press! "C-h .")
  (test-runner:wait-until (lambda () (pair? (docs-at-point-display-test/signatures:asked))))
  (check-equal? (list notes-view) (docs-at-point-display-test/signatures:asked!)))

(test "g in *Docs*, about another view, shows the docs in the echo area: the user asked"
  (test-user:press! "g")
  (test-runner:wait-until (lambda () (equal? "beta: (beta x)\nbeta: Takes **beta**." (echo-area:current-message))))
  (check-equal? other-view (layout:selected-view)))

(test "q quits the view of *Docs*"
  (test-user:press! "q")
  (check (not (eq? (docs) (views:buffer other-view)))))

(test "once the view the docs are about is gone, g raises"
  (layout:select! notes-view)
  (let ([third (layout-split:split-view! notes-view (layout-split:direction column))])
    (layout:select! third)
    (docs-at-point-display-test/signatures:asked!)
    (test-user:press! "C-h .")
    (test-runner:wait-until (lambda () (pair? (docs-at-point-display-test/signatures:asked))))
    (test-user:settle)
    (layout:delete-part! (layout:view-node third))
    (test-user:settle)
    (layout:select! notes-view)
    (check-raises (raised? 'docs-at-point-display:refresh "The view the docs are about is gone") (docs-at-point-display:refresh))))

(test "a plain doc shows in a code block, its thing in its face and its ranges in theirs"
  (define (faced v)
    (docs-at-point:make-doc "(total items)"
      (docs-at-point:doc-options [thing "total"] [face faces:function] [spans (list (list 7 12 faces:highlight))])))
  (options:set! docs-at-point:mode #t)
  (hooks:remove! docs-at-point:sources docs-at-point-display-test/signatures:signature)
  (hooks:remove! docs-at-point:sources docs-at-point-display-test/signatures:described)
  (hooks:add! docs-at-point:sources faced)
  (test-user:press! "C-h .")
  (test-runner:wait-until (docs-text-is? "total\n(total items)\n"))
  (test-user:settle)
  (let ([faced-texts (lambda (face)
                       (map test-user:element-text
                            (filter (lambda (e) (equal? (symbol->string face) (test-user:element-attribute e "data-face")))
                                    (test-user:elements-with (test-user:screen) "data-face"))))])
    (check (member "total" (faced-texts faces:function)))
    (check (member "items" (faced-texts faces:highlight)))
    (check-equal? '("(total items)") (texts "markdown-code-block")))
  (hooks:remove! docs-at-point:sources faced))

(test "where no source answers, C-h . shows *Docs* empty; making *Docs* again runs docs-mode-hook in it"
  (let ([made '()])
    (hooks:add! docs-at-point-display:docs-mode-hook (lambda () (set! made (cons (buffers:current) made))))
    (buffers:kill! (docs))
    (test-user:press! "C-h .")
    (test-runner:wait-until (lambda () (docs)))
    (test-user:settle)
    (check-equal? (list (docs) "" #t) (list (car made) (docs-text) (pair? (views:showing (docs)))))))

(test "docs-mode derives from special; in *Docs* g refreshes and docs-at-point:mode is off"
  (check (modes:derived? docs-at-point-display:docs-mode modes:special))
  (buffers:with-buffer (docs)
    (check-equal? (list docs-at-point-display:refresh #f) (list (buffers:revert-function) (docs-at-point:mode)))))

(test "C-h . keeps its answer though the source is slower than the delay: the idle after its command finds the place it asked about"
  (let ([held #f])
    (define (slower v)
      (suspend (lambda (resume) (set! held resume)))
      (docs-at-point:make-doc "slower doc" (docs-at-point:doc-options [thing "s2"])))
    (hooks:add! docs-at-point:sources slower)
    (layout:select! notes-view)
    (test-user:press! "C-h .")
    (test-runner:wait-until (lambda () held))
    (past-delay)
    (held void)
    (test-runner:wait-until (docs-text-is? "s2\nslower doc\n"))
    (test-runner:wait-until (lambda () (equal? "s2: slower doc" (echo-area:current-message))))
    (hooks:remove! docs-at-point:sources slower)))
