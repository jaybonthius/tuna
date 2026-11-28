(import (tuna) (test) (test-user) (test-runner) (options) (views) (buffers) (document) (layout) (layout-split) (keys)
        (commands) (search) (jump-history) (flash) (flash-test))

(define start "foo fob for\nbar |foo\nfox\nFoo\n")

(define (split-with! text)
  (flash-test:show! start)
  (let ([first (flash-test:view)] [before (layout:views)])
    (flash-test:press! "C-x 2")
    (let ([second (find (lambda (v) (not (memq v before))) (layout:views))])
      (views:set-buffer! second (buffers:make (buffers:free-name "*other*") text))
      (test-user:settle)
      (values first second))))

(define (unsplit! first)
  (layout:select! first)
  (layout:reset-layout)
  (test-user:settle))

;; A jump started with its pattern given labels its matches afresh, as
;; typing it would not: a match keeps the label an earlier character
;; gave it.
(define given "")

(commands:define-command (jump-to-given)
  "Jumps with the pattern the test gave already typed."
  (let ([target (flash:read-match (search:make-query given))])
    (when target (flash:go-to target))))

(keys:bind! keys:global "C-c m" jump-to-given)

(test "a jump labels the selected view's matches by distance, then each other view's from its top, and the match at point last of all"
  (let-values ([(first second) (split-with! "x\nother foo\n")])
    (set! given "foo")
    (flash-test:press! "C-c m")
    (check-equal? '("{s}foo fob for" "bar {f}foo" "fox" "{a}Foo" "") (flash-test:lines first))
    (check-equal? '("x" "other {d}foo" "") (flash-test:lines second))
    (let ([left (views:point first)])
      (flash-test:press! "d")
      (check (eq? second (layout:selected-view)))
      (check-equal? "x\nother |foo\n" (flash-test:text))
      (check-equal? (cons (views:buffer first) left) (car (jump-history:places))))
    (unsplit! first)))

(test "with a prefix argument, or with all-views off, a jump covers the selected view only"
  (let-values ([(first second) (split-with! "x\nother foo\n")])
    (flash-test:press! "C-u C-c ; f o o")
    (check-equal? '("x" "other foo" "") (flash-test:lines second))
    (check-equal? "Flash [foo] (3): " (flash-test:prompt))
    (check (flash-test:quitting! "C-g"))
    (options:set! flash:all-views #f)
    (flash-test:press! "C-c ; f o o")
    (check-equal? '("x" "other foo" "") (flash-test:lines second))
    (check (flash-test:quitting! "C-g"))
    (options:unset! flash:all-views)
    (unsplit! first)))

(test "a match in a fold, or outside the view's narrowing, is no target"
  (flash-test:show! start)
  (let ([v (flash-test:view)])
    (views:fold! v (flash-test:position 20) (flash-test:position 23))
    (flash-test:press! "C-c ; f o")
    (check-equal? "Flash [fo] (5): " (flash-test:prompt))
    (check (flash-test:quitting! "C-g"))
    (views:unfold! v (flash-test:position 20))
    (views:narrow! v (flash-test:position 0) (flash-test:position 19))
    (flash-test:press! "C-c ; f o")
    (check-equal? "Flash [fo] (4): " (flash-test:prompt))
    (check (flash-test:quitting! "C-g"))
    (views:widen! v)))

(test "a match where point cannot rest, as in a node with no stops, is no target; a match in an atom's text labels the atom, and its label puts point before it"
  (let ([b (buffers:make (buffers:free-name "*blocks*")
             (flash-test:page '() (flash-test:para '() "a fox\n") (flash-test:quiet '() "a fox\n")
                                  (flash-test:word '((text . "foxtrot"))) (flash-test:para '() "end\n")))])
    (flash-test:show-buffer! b)
    (flash-test:press! "C-c ; f o x")
    (check-equal? "Flash [fox] (2): " (flash-test:prompt))
    (let ([atom-labels (filter (lambda (e) (equal? "node whole" (test-user:element-attribute e "class")))
                               (flash-test:with-attribute "data-flash-label"))])
      (check-equal? 1 (length atom-labels))
      (flash-test:press! (test-user:element-attribute (car atom-labels) "data-flash-label")))
    (let* ([v (flash-test:view)] [t (document:token (buffers:document b) (views:point v))])
      (check (and (document:node? t) (document:atom? t))))))

(test "a hand scroll leaves the marks as drawn until the next character, which searches what the view shows then"
  (flash-test:show! start)
  (flash-test:press! "C-c ; f")
  (let ([before (flash-test:lines)] [v (flash-test:view)])
    (flash-test:show-range! v (flash-test:position 20) (flash-test:position 28))
    (test-user:settle)
    (check-equal? before (flash-test:lines))
    (flash-test:press! "o")
    (check-equal? '("foo fob for" "bar foo" "{a}fox" "{d}Foo" "") (flash-test:lines))
    (check (flash-test:quitting! "C-g"))
    (flash-test:show-all! v)))

(define (twenty-columns body-size view client) (values 20 5))

(test "where lines do not wrap, a match past the columns shown is no target, its column counted with the buffer's tab width"
  (flash-test:show! "|\t\tfox\nfox\n")
  (let ([v (flash-test:view)])
    (views:with-view v (options:set-local! views:wrap-lines #f))
    (advice-add! views:body-size twenty-columns)
    (set! given "fox")
    (flash-test:press! "C-c m")
    (check-equal? '("\t\t{a}fox" "{s}fox" "") (flash-test:lines v))
    (check (flash-test:quitting! "C-g"))
    (buffers:with-buffer (views:buffer v) (options:set-local! views:tab-width 16))
    (flash-test:press! "C-c m")
    (check-equal? '("\t\tfox" "{a}fox" "") (flash-test:lines v))
    (check (flash-test:quitting! "C-g"))
    (advice-remove! views:body-size twenty-columns)
    (buffers:with-buffer (views:buffer v) (options:unset-local! views:tab-width))
    (views:with-view v (options:unset-local! views:wrap-lines))))
