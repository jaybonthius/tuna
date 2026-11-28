(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (modes) (buffers) (document) (views) (layout)
        (layout-split) (editing) (jump-history) (completion) (completion-list) (minibuffer) (outline) (outline-picker)
        (chez-scheme) (completion-test sessions) (completion-test picking) (outline-picker-test reading) (minibuffer-test screen))

(define src-text
  (string-append "(define (alpha x) x)\n(define beta 2)\n(define-record-type point (fields x y))\n"
                 "(define-syntax swap! (syntax-rules ()))\n(let loop ((i 0)) i)\n  (define (indented y) y)\n"
                 "(define (omega) 1)\n(alpha 1)\n(display beta)\n"))

(define src (buffers:make "src.scm" src-text))
(modes:set-major-mode chez-scheme:mode src)
(test-runner:wait-until (lambda () (chez-scheme:outline-source src)))

(define view outline-picker-test/reading:view)
(define place-of outline-picker-test/reading:place-of)
(define here outline-picker-test/reading:here)
(define go! outline-picker-test/reading:go!)
(define session outline-picker-test/reading:session)
(define rows outline-picker-test/reading:rows)
(define quit! outline-picker-test/reading:quit!)

(define (choose! keys) (completion-test/picking:press-until-ended! keys outline-picker:entry))

(test "M-g i asks Go to item: with one candidate for each entry, grouped by kind in the order the kinds first come, each group in buffer order"
  (go! src 2 3)
  (test-user:press! "M-g i")
  (check-equal? '(("Functions" "alpha") ("Functions" "indented") ("Functions" "omega") ("Variables" "beta")
                  ("Structs" "point") ("Macros" "swap!"))
                (rows))
  (check-equal? '("Go to item: ") (minibuffer-test/screen:questions))
  (quit!))

(test "C-n previews the selected entry in the starting view, its line highlighted and point on its name; C-g puts point back and records nothing"
  (go! src 2 3)
  (let ([start (view)] [before (length (jump-history:places))])
    (test-user:press! "M-g i")
    (rows)
    (test-user:press! "C-n")
    (test-runner:wait-until (lambda () (equal? '("src.scm" 6 11) (place-of start))))
    (check (pair? (filter (lambda (e) (equal? "highlight" (test-user:element-attribute e "data-face")))
                          (test-user:elements-with (test-user:screen) "data-face"))))
    (quit!)
    (check-equal? '("src.scm" 2 3) (here))
    (check-equal? before (length (jump-history:places)))))

(test "choosing goes to the entry's name, recentres through jump-history:after-jump, and records the place left so M-, returns"
  (go! src 2 3)
  (let ([jumps 0])
    (define (note v) (set! jumps (+ jumps 1)))
    (hooks:add! jump-history:after-jump note)
    (test-user:press! "M-g i")
    (test-user:type! "omega")
    (rows)
    (set! jumps 0)
    (choose! "RET")
    (check-equal? '("src.scm" 7 9) (here))
    (check-equal? 1 jumps)
    (hooks:remove! jump-history:after-jump note))
  (test-user:press! "M-,")
  (check-equal? '("src.scm" 2 3) (here)))

(test "with point on a call of alpha the default is alpha, first in the read, and RET with nothing typed goes to its name"
  (go! src 8 2)
  (test-user:press! "M-g i")
  (rows)
  (check-equal? "alpha" (completion:session-default (session)))
  (check-equal? '("Functions" "alpha") (car (rows)))
  (choose! "RET")
  (check-equal? '("src.scm" 1 9) (here)))

(test "with point on beta the default's group, Variables, comes first, so RET with nothing typed goes to beta"
  (go! src 9 10)
  (test-user:press! "M-g i")
  (check-equal? '("Variables" "beta") (car (rows)))
  (check-equal? "beta" (completion-test/picking:selected))
  (choose! "RET")
  (check-equal? '("src.scm" 2 8) (here)))

(test "with point on a symbol no entry matches, or on white space, there is no default and the selection is the first candidate"
  (go! src 5 6)
  (test-user:press! "M-g i")
  (rows)
  (check-equal? #f (completion:session-default (session)))
  (quit!)
  (go! src 1 17)
  (test-user:press! "M-g i")
  (rows)
  (check-equal? #f (completion:session-default (session)))
  (check-equal? "alpha" (completion-test/picking:selected))
  (quit!))

(test "outline-picker:find-default prefers an entry named exactly, then one starting, ending or holding the name, ignoring case, the first in the list winning"
  (let ([candidates '(("x/precost" . "precost") ("costly" . "costly") ("Cost" . "Cost") ("accosted" . "accosted"))])
    (check-equal? '("Cost" "costly" "x/precost" "accosted" #f)
                  (map (lambda (name) (outline-picker:find-default name candidates)) '("cost" "cos" "recost" "cco" "zzz")))))

(test "a kind's narrow character followed by SPC shows only that kind's entries"
  (go! src 2 3)
  (test-user:press! "M-g i")
  (rows)
  (test-user:type! "f ")
  (check-equal? '("alpha" "indented" "omega") (map cadr (rows)))
  (quit!))

(test "the chosen texts are the read's history, which M-p offers"
  (go! src 2 3)
  (test-user:press! "M-g i")
  (test-user:type! "beta")
  (rows)
  (choose! "RET")
  (check-equal? "beta" (car (outline-picker:history)))
  (test-user:press! "M-g i")
  (test-user:press! "M-p")
  (check-equal? "beta" (minibuffer:input (minibuffer:current-prompt)))
  (quit!))

(test "an edit during the read moves the jump to where the entry is now"
  (go! src 2 3)
  (test-user:press! "M-g i")
  (test-user:type! "omega")
  (rows)
  (let ([line-7 (document:line-start (buffers:document src) 7)])
    (buffers:replace! src line-7 line-7 "  "))
  (choose! "RET")
  (check-equal? '("src.scm" 7 11) (here))
  (let ([line-7 (document:line-start (buffers:document src) 7)])
    (buffers:replace! src line-7 (+ line-7 2) "")))

(test "in a buffer two views show, the previews and the jump are in the view M-g i was pressed in"
  (go! src 2 3)
  (test-user:press! "C-x 2")
  (let* ([start (view)] [other (find (lambda (v) (not (eq? v start))) (layout:views))] [kept (place-of other)])
    (test-user:press! "M-g i")
    (rows)
    (test-user:press! "C-n")
    (test-runner:wait-until (lambda () (equal? '("src.scm" 6 11) (place-of start))))
    (check-equal? kept (place-of other))
    (choose! "RET")
    (check-equal? '("src.scm" 6 11) (place-of start))
    (check-equal? kept (place-of other)))
  (layout:reset-layout))

;; A plain buffer whose outline a test gives, to show what Scheme's has
;; not: nesting, kinds no table knows, names given twice.
(define plain-text "class Cart:\n  def total(): pass\ndef foo(): pass\ndef foo(): pass\ngizmo g\n")

(define plain (buffers:make "plain.txt" plain-text))

(define (at word nth)
  (let ([n (string-length word)])
    (let loop ([i 0] [k nth])
      (cond
        [(not (string=? (substring plain-text i (+ i n)) word)) (loop (+ i 1) k)]
        [(> k 0) (loop (+ i 1) (- k 1))]
        [else (+ i 1)]))))

(define (plain-outline b)
  (outline:make-outline b (buffers:version b)
    (list (outline:make-parent (outline:make-entry "Cart" 'class (at "class" 0) (at "def foo" 0) (at "Cart" 0))
            (list (outline:make-entry "total" 'method (at "def total" 0) (at "pass" 0) (at "total" 0))))
          (outline:make-entry "foo" 'function (at "def foo" 0) (at "def foo" 1) (at "foo" 0))
          (outline:make-entry "foo" 'function (at "def foo" 1) (at "gizmo" 0) (at "foo" 1))
          (outline:make-entry "g" 'gizmo (at "gizmo" 0) (+ (at "gizmo" 0) 7) (at "g\n" 0)))))

(buffers:with-buffer plain (hooks:add-local! outline:sources plain-outline))

(test "a parent is a candidate as each child is, a child's text holds its parents' names, and typing its words in any order finds it"
  (go! plain 5 0)
  (test-user:press! "M-g i")
  (check-equal? '(("Classes" "Cart") ("Methods" "Cart/total") ("Functions" "foo") ("Functions" "foo (1)") ("Other" "g"))
                (rows))
  (test-user:type! "total cart")
  (check-equal? '("Cart/total") (map cadr (rows)))
  (quit!))

(test "RET on a parent goes to its name"
  (go! plain 5 0)
  (test-user:press! "M-g i")
  (test-user:type! "Cart")
  (rows)
  (choose! "RET")
  (check-equal? '("plain.txt" 1 6) (here)))

(test "a kind outline:kinds does not know is in the group Other, which o narrows to"
  (go! plain 5 0)
  (test-user:press! "M-g i")
  (rows)
  (test-user:type! "o ")
  (check-equal? '(("Other" "g")) (rows))
  (quit!))

(define (raised-message keys)
  (let ([reported (test-runner:reports-during (lambda () (test-user:press! keys)))])
    (map (lambda (c) (and (message-condition? c) (condition-message c))) reported)))

(test "a buffer no source answers for raises This buffer has no outline, and an empty outline The outline is empty; nothing moves"
  (let ([none (buffers:make "none.txt" "text")] [empty (buffers:make "empty.txt" "text")])
    (buffers:with-buffer empty
      (hooks:add-local! outline:sources (lambda (b) (outline:make-outline b (buffers:version b) '()))))
    (go! none 1 2)
    (check-equal? '("This buffer has no outline") (raised-message "M-g i"))
    (check-equal? '("none.txt" 1 2) (here))
    (go! empty 1 2)
    (check-equal? '("The outline is empty") (raised-message "M-g i"))
    (check-equal? '("empty.txt" 1 2) (here))))

(test "C-g while a source is still answering quits the command, and nothing moves"
  (let ([slow (buffers:make "slow.txt" "text")] [asked? #f])
    (buffers:with-buffer slow
      (hooks:add-local! outline:sources (lambda (b) (set! asked? #t) (suspend (lambda (resume) (void))))))
    (go! slow 1 2)
    (test-user:press! "M-g i")
    (test-runner:wait-until (lambda () asked?))
    (quit!)
    (check-equal? '("slow.txt" 1 2) (here))))
