(import (tuna) (test) (test-user) (buffers) (views) (layout) (layout-split) (search) (occur) (isearch-test) (occur-test))

(define wins occur-test:wins)

(define b (occur-test:src! "one foo\ntwo\nfoo three foo\nfour\n"))

(occur-test:occur! (occur-test:rx "foo") 1 #f)

(define ov (occur-test:occur-view))

(define at (+ 2 (occur-test:find-text (occur-test:occur-buffer) "foo three")))

(define (select-occur!) (layout:select! ov) (test-user:settle))

(test "a click on a listed line's text follows it: the press moves *Occur*'s point there, then the source is shown and selected at the line's first match"
  (test-user:settle)
  (test-user:click! ov at)
  (check-equal? (list '(("src" 13 #t) ("*Occur*" 68 #f)) 68) (list (wins) (views:point ov))))

(test "a click at the start of another listed line follows it too"
  (select-occur!)
  (test-user:click! ov (occur-test:find-text (occur-test:occur-buffer) "one foo"))
  (check-equal? '(("src" 5 #t) ("*Occur*" 50 #f)) (wins)))

(test "mouse-2 follows and leaves *Occur*'s point where it was"
  (select-occur!)
  (views:set-point! ov 2)
  (test-user:settle)
  (test-user:click! ov at "<mouse-2>")
  (check-equal? (list '(("src" 13 #t) ("*Occur*" 2 #f)) 2) (list (wins) (views:point ov))))

(test "mouse-2 with the source's view selected follows in that view, and *Occur* keeps its view"
  (let ([sv (occur-test:source-view b)])
    (views:set-point! sv 1)
    (layout:select! sv)
    (test-user:settle)
    (test-user:click! ov at "<mouse-2>")
    (check-equal? (list '(("src" 13 #t) ("*Occur*" 2 #f)) #t) (list (wins) (eq? (occur-test:view) sv)))))

(test "with one view, a click splits a view for the source"
  (select-occur!)
  (occur-test:only!)
  (test-user:settle)
  (test-user:click! ov at)
  (check-equal? '(("*Occur*" 68 #f) ("src" 13 #t)) (wins)))

(test "a click on a context line or the heading only sets point"
  (select-occur!)
  (occur-test:only!)
  (test-user:settle)
  (test-user:click! ov (occur-test:find-text (occur-test:occur-buffer) "two"))
  (check-equal? (list '(("*Occur*" 60 #t)) 60) (list (wins) (views:point ov)))
  (test-user:click! ov 3)
  (check-equal? '(("*Occur*" 3 #t)) (wins)))

(test "a drag over a listed line selects and follows nothing"
  (test-user:drag! ov at (+ at 5))
  (check-equal? (list '(("*Occur*" 73 #t)) 68) (list (wins) (views:mark ov))))
