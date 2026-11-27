(import (tuna) (test) (test-user) (hooks) (modes) (buffers) (document) (views) (layout) (layout-split) (editing) (undo)
        (search) (occur) (isearch-test) (occur-test))

(define wins occur-test:wins)

(define b (occur-test:src! "one foo\ntwo\nfoo three foo\nfour\n"))

(define (source) (occur-test:text-of b))

(define at-line!
  (case-lambda
    [(text) (at-line! text 0)]
    [(text offset) (views:set-point! (occur-test:view) (+ (occur-test:find-text (occur-test:occur-buffer) text) offset))]))

(buffers:define-layer locked (read-only))

(test "e switches to occur:edit-mode and says how to leave; it runs occur:mode-hook's entries before occur:edit-mode-hook's"
  (let* ([ran '()]
         [in-mode (lambda () (set! ran (cons (list 'occur (modes:major-mode (buffers:current))) ran)))]
         [in-edit (lambda () (set! ran (cons (list 'edit (modes:major-mode (buffers:current))) ran)))])
    (hooks:add! occur:mode-hook in-mode)
    (hooks:add! occur:edit-mode-hook in-edit)
    (occur-test:occur! (occur-test:rx "foo") 1 #f)
    (occur-test:in-occur!)
    (occur-test:only!)
    (occur-test:clear-messages!)
    (test-user:press! "e")
    (check-equal? '(occur:edit-mode "Editing: Type C-c C-c to return to Occur mode."
                    ((occur occur:mode) (occur occur:edit-mode) (edit occur:edit-mode)))
                  (list (modes:major-mode (views:buffer (occur-test:view))) (occur-test:last-message) (reverse ran)))
    (hooks:remove! occur:mode-hook in-mode)
    (hooks:remove! occur:edit-mode-hook in-edit)))

(test "an edit to a listed line is made at its place in the source, shown in another view, not selected, its point at the edit and centred"
  (let* ([placements '()]
         [note (lambda (orig v p align) (set! placements (cons (list (buffers:name (views:buffer v)) p align) placements)) (orig v p align))])
    (advice-add! views:scroll-to! note)
    (at-line! "foo three" 4)
    (test-user:press! "X")
    (advice-remove! views:scroll-to! note)
    (check-equal? '("3 matches in 2 lines for \"foo\" in buffer: src\none foo\ntwo\nfoo Xthree foo\nfour\n" "one foo\ntwo\nfoo Xthree foo\nfour\n"
                    (("*Occur*" 71 #t) ("src" 18 #f)))
                  (list (occur-test:listed) (source) (wins)))
    (check-equal? (list (list "src" 18 (views:align center))) placements)))

(test "undo in *Occur* is an edit too"
  (test-user:press! "C-/")
  (check-equal? "one foo\ntwo\nfoo three foo\nfour\n" (source)))

(test "the heading, a number and a context line refuse edits"
  (views:set-point! (occur-test:view) 3)
  (check-equal? '("a read-only span refuses the edit") (occur-test:reported "Z"))
  (at-line! "two")
  (check-equal? '("a read-only span refuses the edit") (occur-test:reported "Z"))
  (check-equal? "one foo\ntwo\nfoo three foo\nfour\n" (source)))

(test "a line break is refused with a sentence"
  (at-line! "one foo")
  (check-equal? '("An occur line takes no line break") (occur-test:reported "RET")))

(test "a source line changed since the listing refuses the edit, so no change in the source is lost"
  (buffers:replace! b 4 4 "!")
  (at-line! "one foo" 7)
  (check-equal? '("The source line changed; g lists it again") (occur-test:reported "Y"))
  (check-equal? "one! foo\ntwo\nfoo three foo\nfour\n" (source)))

(test "a change at the line's start keeps the line reading as listed, so the edit lands in place"
  (buffers:replace! b 4 5 "")
  (buffers:replace! b 1 1 ">> ")
  (test-user:press! "Y")
  (check-equal? ">> one fooY\ntwo\nfoo three foo\nfour\n" (source))
  (buffers:replace! b 1 4 "")
  (test-user:press! "Y")
  (check-equal? "one fooYY\ntwo\nfoo three foo\nfour\n" (source)))

(test "a source that refuses the edit leaves *Occur*'s edit and says so"
  (buffers:add-span! (buffers:layer b locked) 1 (- (document:length (buffers:document b)) 1) 'locked)
  (at-line! "one fooY" 8)
  (occur-test:clear-messages!)
  (test-user:press! "W")
  (check-equal? '("3 matches in 2 lines for \"foo\" in buffer: src\none fooYWY\ntwo\nfoo three foo\nfour\n" "one fooYY\ntwo\nfoo three foo\nfour\n" "Buffer ‘src’ is read only.")
                (list (occur-test:listed) (source) (occur-test:last-message)))
  (buffers:remove-span! (buffers:layer b locked) 'locked))

(test "C-o shows the match in another view, and a click follows a line, in edit mode too"
  (at-line! "foo three")
  (test-user:press! "C-o")
  (check-equal? '(("*Occur*" 69 #t) ("src" 15 #f)) (wins))
  (test-user:settle)
  (test-user:click! (occur-test:view) (+ 2 (occur-test:find-text (occur-test:occur-buffer) "foo three")))
  (check-equal? '(("*Occur*" 71 #f) ("src" 15 #t)) (wins)))

(test "C-c C-c goes back to occur:mode and says so; edits are then refused"
  (occur-test:in-occur!)
  (occur-test:clear-messages!)
  (test-user:press! "C-c C-c")
  (check-equal? '(occur:mode "Switching to Occur mode.") (list (modes:major-mode (views:buffer (occur-test:view))) (occur-test:last-message)))
  (check-equal? '("W is undefined") (occur-test:reported "W")))

(test "an edit made while another buffer is current is checked against the listing it is made in"
  (test-user:press! "e")
  (buffers:replace! b 4 4 "!")
  (let ([at (+ (occur-test:find-text (occur-test:occur-buffer) "one foo") 7)] [other (buffers:make "other" "x\n")])
    (check-equal? "The source line changed; g lists it again"
                  (guard (c [(message-condition? c) (condition-message c)])
                    (buffers:with-buffer other (buffers:replace! (occur-test:occur-buffer) at at "Y")))))
  (check-equal? "one! fooYY\ntwo\nfoo three foo\nfour\n" (source)))

(test "a collected string is not a line of its source, so it takes no edit"
  (occur-test:occur! (occur-test:rx "f(o)o") 0 "\\1")
  (occur-test:in-occur!)
  (test-user:press! "e")
  (at-line! "o\n")
  (check-equal? '("A collected string is not a line of its source") (occur-test:reported "W"))
  (check-equal? "one! fooYY\ntwo\nfoo three foo\nfour\n" (source)))
