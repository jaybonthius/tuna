(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (buffers) (views) (layout) (layout-split) (editing)
        (jump-history) (search) (occur) (isearch-test) (occur-test))

(define rx occur-test:rx)
(define occur! occur-test:occur!)
(define wins occur-test:wins)

(define (at-line! text) (views:set-point! (occur-test:view) (occur-test:find-text (occur-test:occur-buffer) text)))

(define jumped '())

(define (note-jump v) (set! jumped (cons (list (buffers:name (views:buffer v)) (views:point v)) jumped)))

(define b #f)

(test "RET on a listed line shows the source in the view already showing it, selected, at the line's first match; *Occur* stays in its view"
  (set! b (occur-test:src! "one foo\ntwo\nfoo three foo\nfour\n"))
  (views:set-point! (occur-test:view) 20)
  (hooks:add! jump-history:after-jump note-jump)
  (occur! (rx "foo") 0 #f)
  (occur-test:in-occur!)
  (at-line! "foo three")
  (test-user:press! "RET")
  (check-equal? (list '(("src" 13 #t) ("*Occur*" 60 #f)) (list (cons b 20)) '(("src" 13)))
                (list (wins) (jump-history:places) jumped))
  (hooks:remove! jump-history:after-jump note-jump))

(test "the line's matches are highlighted in the source until the next command, and the visited line is marked in *Occur*"
  (check-equal? '("foo" "foo") (occur-test:pulsed (occur-test:view)))
  (check-equal? 3 (occur-test:marked))
  (test-user:press! "C-f")
  (check-equal? '() (occur-test:pulsed (occur-test:view)))
  (test-user:press! "M-,")
  (check-equal? '(("src" 20 #t) ("*Occur*" 60 #f)) (wins)))

(test "with *Occur* the only view, a view is split for the source, and the jump records the source where it was shown"
  (occur-test:in-occur!)
  (occur-test:only!)
  (at-line! "one foo")
  (test-user:press! "RET")
  (check-equal? '(("*Occur*" 50 #f) ("src" 5 #t)) (wins))
  (check-equal? (cons b 1) (car (jump-history:places))))

(test "o shows the source in a view other than *Occur*'s and selects it, with no highlight; the jump is recorded"
  (occur-test:in-occur!)
  (at-line! "foo three")
  (test-user:press! "o")
  (check-equal? (list '(("*Occur*" 60 #f) ("src" 13 #t)) (cons b 5) '())
                (list (wins) (car (jump-history:places)) (occur-test:pulsed (occur-test:view))))
  (check-equal? 3 (occur-test:marked)))

(test "C-o shows the match highlighted for a moment, keeps *Occur* selected and records no jump"
  (occur-test:in-occur!)
  (at-line! "one foo")
  (let ([places (length (jump-history:places))])
    (test-user:press! "C-o")
    (let ([sv (occur-test:source-view b)])
      (check-equal? (list '(("*Occur*" 50 #t) ("src" 5 #f)) places '("foo"))
                    (list (wins) (length (jump-history:places)) (occur-test:pulsed sv)))
      (check-equal? 1 (occur-test:marked))
      (test-runner:wait-until (lambda () (null? (occur-test:pulsed sv)))))))

(test "the source's active region stays active and grows to the match"
  (let ([sv (occur-test:source-view b)])
    (layout:select! sv)
    (views:set-point! sv 4)
    (views:set-mark! sv 1)
    (occur-test:in-occur!)
    (at-line! "foo three")
    (test-user:press! "RET")
    (check-equal? '(13 1) (list (views:point (occur-test:view)) (views:mark (occur-test:view))))
    (views:set-mark! (occur-test:view) #f)))

(test "RET on the heading or a context line has no occurrence; a new listing clears the mark"
  (occur! (rx "foo") 1 #f)
  (check-equal? #f (occur-test:marked))
  (occur-test:in-occur!)
  (at-line! "two")
  (check-equal? '("No occurrence on this line") (occur-test:reported "RET"))
  (views:set-point! (occur-test:view) 2)
  (check-equal? '("No occurrence on this line") (occur-test:reported "RET"))
  (check-equal? '(("*Occur*" 2 #t) ("src" 13 #f)) (wins)))

(test "RET on a line whose source was killed says so"
  (at-line! "one foo")
  (buffers:kill! b)
  (check-equal? '("Buffer for this occurrence was killed") (occur-test:reported "RET")))

(test "a separator and an unmatched current line hold no occurrence either"
  (occur-test:src! "foo\na\nb\nc\nfoo\n")
  (occur! (rx "foo") 1 #f)
  (occur-test:in-occur!)
  (test-user:click-element! (car (occur-test:occur-elements "occur-separator")))
  (check-equal? '("No occurrence on this line") (occur-test:reported "RET"))
  (occur-test:only!)
  (occur-test:src! "one foo\ntwo\n")
  (views:set-point! (occur-test:view) 10)
  (options:set! occur:jump-to-current-line #t)
  (occur! (rx "foo") 0 #f)
  (options:set! occur:jump-to-current-line #f)
  (occur-test:in-occur!)
  (check-equal? "two" (occur-test:where))
  (check-equal? '("No occurrence on this line") (occur-test:reported "RET")))

(test "RET marks only the line's matches in the source, through pulse"
  (occur-test:only!)
  (let ([m (occur-test:src! "foo three foo\n")])
    (occur! (rx "foo") 0 #f)
    (occur-test:in-occur!)
    (at-line! "foo three")
    (test-user:press! "RET")
    (check-equal? '(("pulse.highlight" "foo") ("pulse.highlight" "foo")) (isearch-test:faced (test-user:client)))))

(test "C-o, n and p show a place without recentring the source's view; RET, a jump, recentres it"
  (let* ([centred '()]
         [note (lambda (orig v p align) (when (eq? align (views:align center)) (set! centred (cons (buffers:name (views:buffer v)) centred))) (orig v p align))])
    (advice-add! views:scroll-to! note)
    (occur-test:in-occur!)
    (at-line! "foo three")
    (test-user:press! "C-o")
    (check-equal? '(("foo" "foo") ()) (list (occur-test:pulsed (occur-test:source-view (buffers:find "src"))) centred))
    (test-user:press! "M-< n")
    (check-equal? '() centred)
    (test-user:press! "RET")
    (check-equal? '("src") centred)
    (advice-remove! views:scroll-to! note)))
