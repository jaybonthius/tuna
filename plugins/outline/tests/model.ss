(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (modes) (tables) (buffers) (document)
        (views) (layout) (editing) (outline))

(options:set! outline:idle-delay 0.05)

;; Keys typed here end in an idle period, which the idle remakes wait for.
(test-user:show! "|")

(define (idle!) (test-user:type! "x"))

(define (fresh text) (buffers:make (buffers:free-name "src") text))

(define (at b offset) (+ offset 1))

(define (entry b name kind start end) (outline:make-entry name kind (at b start) (at b end) (at b start)))

(define (names o) (map outline:entry-name (outline:roots o)))

(define (words-outline b)
  (let* ([doc (buffers:document b)] [text (document:text doc)] [n (string-length text)])
    (outline:make-outline b (buffers:version b)
      (let loop ([i 0] [acc '()])
        (cond
          [(fx= i n) (reverse acc)]
          [(char-whitespace? (string-ref text i)) (loop (fx+ i 1) acc)]
          [else
           (let ([end (let find ([j i]) (if (or (fx= j n) (char-whitespace? (string-ref text j))) j (find (fx+ j 1))))])
             (loop end (cons (entry b (substring text i end) 'function i end) acc)))])))))

(define %calls (make-eq-hashtable))

(define (calls name) (eq-hashtable-ref %calls name 0))

(define (stub name answer)
  (lambda (b)
    (eq-hashtable-update! %calls name (lambda (n) (+ n 1)) 0)
    (answer b)))

(define (add-sources! b . sources)
  (buffers:with-buffer b
    (for-each (lambda (s k) (hooks:add-local! outline:sources s k)) sources (iota (length sources)))))

(define (only b source) (lambda (x) (and (eq? x b) (source x))))

(define (edit! b) (buffers:replace! b (at b 0) (at b 0) "w "))

(test "outline:get gives the first source's outline and calls no later source"
  (let ([b (fresh "alpha beta")])
    (add-sources! b (stub 'first words-outline) (stub 'second words-outline))
    (check-equal? '("alpha" "beta") (names (outline:get b)))
    (check-equal? '(1 0) (list (calls 'first) (calls 'second)))))

(test "a source that answers #f gives way to the next"
  (let ([b (fresh "alpha")])
    (add-sources! b (stub 'none (lambda (b) #f)) (stub 'after-none words-outline))
    (check-equal? '("alpha") (names (outline:get b)))))

(test "an outline with no roots is an answer, and no later source is called"
  (let ([b (fresh "alpha")])
    (add-sources! b (stub 'empty (lambda (b) (outline:make-outline b (buffers:version b) '())))
                  (stub 'after-empty words-outline))
    (check-equal? '() (names (outline:get b)))
    (check-equal? 0 (calls 'after-empty))))

(test "a source that raises is reported once for its buffer however often it is asked, and the next source is called each time"
  (let ([b (fresh "alpha")])
    (add-sources! b (stub 'broken (lambda (b) (error 'broken-source "broken"))) (stub 'after-broken words-outline))
    (let ([reported (test-runner:reports-during
                      (lambda ()
                        (outline:get b)
                        (edit! b)
                        (outline:get b)
                        (edit! b)
                        (outline:get b)))])
      (check-equal? 1 (length reported))
      (check-equal? '(3 3) (list (calls 'broken) (calls 'after-broken))))))

(test "when no source answers, the answer #f is kept until a source that becomes ready forgets it"
  (let* ([b (fresh "alpha")] [ready? #f])
    (add-sources! b (stub 'late (lambda (b) (and ready? (words-outline b)))))
    (check-equal? #f (outline:get b))
    (check-equal? #f (outline:get b))
    (check-equal? 1 (calls 'late))
    (set! ready? #t)
    (outline:forget! b)
    (check-equal? '("alpha") (names (outline:get b)))
    (check-equal? 2 (calls 'late))))

(test "a read buffer no source knows is asked once, not again at each idle period"
  (let ([b (fresh "alpha")] [read (fresh "beta")])
    (add-sources! b (stub 'unknown (lambda (b) #f)))
    (add-sources! read (stub 'witness words-outline))
    (outline:cached b)
    (idle!)
    (test-runner:wait-until (lambda () (= 1 (calls 'unknown))))
    (outline:cached b)
    (outline:cached read)
    (idle!)
    (test-runner:wait-until (lambda () (= 1 (calls 'witness))))
    (check-equal? 1 (calls 'unknown))))

(test "a second get with no edit between calls no source"
  (let ([b (fresh "alpha")])
    (add-sources! b (stub 'unchanged words-outline))
    (let ([o (outline:get b)])
      (check-equal? o (outline:get b))
      (check-equal? 1 (calls 'unchanged)))))

(test "after an edit the sources are asked again and the outline has the buffer's new version"
  (let ([b (fresh "alpha")])
    (add-sources! b (stub 'edited words-outline))
    (outline:get b)
    (edit! b)
    (let ([o (outline:get b)])
      (check-equal? 2 (calls 'edited))
      (check-equal? (buffers:version b) (outline:version o))
      (check-equal? '("w" "alpha") (names o)))))

(define (make-gate) (box '()))

(define (wait-at! gate)
  (unless (eq? (unbox gate) 'open)
    (suspend (lambda (resume) (set-box! gate (cons resume (unbox gate)))))))

(define (open! gate)
  (let ([waiting (unbox gate)])
    (set-box! gate 'open)
    (for-each (lambda (resume) (resume void)) waiting)))

(define (held-source name gate)
  (stub name
    (lambda (b)
      (let ([v (buffers:version b)])
        (wait-at! gate)
        (outline:make-outline b v (list (entry b "alpha" 'function 0 5)))))))

(test "two callers share one asking; cancelling one leaves the other its answer, and the cancel reports nothing"
  (let* ([b (fresh "alpha")] [gate (make-gate)] [got #f] [first-ended #f])
    (add-sources! b (held-source 'shared gate))
    (let ([waiter (spawn-task (lambda (restore)
                                (guard (c [(cancelled? c) (set! first-ended 'cancelled)])
                                  (outline:get b))))])
      (spawn-task (lambda (restore) (set! got (outline:get b))))
      (test-runner:wait-until (lambda () (= 1 (calls 'shared))))
      (check-equal? '()
                    (test-runner:reports-during
                      (lambda ()
                        (cancel-task waiter)
                        (test-runner:wait-until (lambda () first-ended))
                        (open! gate)
                        (test-runner:wait-until (lambda () got)))))
      (check-equal? '(cancelled ("alpha") 1) (list first-ended (names got) (calls 'shared))))))

(test "the asking stops once no caller waits for it"
  (let* ([b (fresh "alpha")] [stopped? #f] [ended #f])
    (add-sources! b (stub 'alone
                      (lambda (b)
                        (guard (c [(cancelled? c) (set! stopped? #t) (raise c)])
                          (wait-at! (make-gate))))))
    (let ([caller (spawn-task (lambda (restore) (guard (c [(cancelled? c) (set! ended #t)]) (outline:get b))))])
      (test-runner:wait-until (lambda () (= 1 (calls 'alone))))
      (check-equal? '() (test-runner:reports-during
                          (lambda ()
                            (cancel-task caller)
                            (test-runner:wait-until (lambda () (and ended stopped?)))))))))

(test "an edit while a source works leaves the answer at the version it started from, and outline:map carries it"
  (let* ([b (fresh "alpha")] [gate (make-gate)] [got #f])
    (add-sources! b (held-source 'held gate))
    (let ([before (buffers:version b)])
      (spawn-task (lambda (restore) (set! got (outline:get b))))
      (test-runner:wait-until (lambda () (= 1 (calls 'held))))
      (edit! b)
      (open! gate)
      (test-runner:wait-until (lambda () got))
      (let ([e (car (outline:roots got))])
        (check-equal? before (outline:version got))
        (check-equal? (at b 7) (outline:map got (outline:entry-end e)))))))

(test "outline:cached gives #f before any outline, the last outline after, and #f once the buffer is killed"
  (let ([b (fresh "alpha")])
    (add-sources! b (stub 'killed words-outline))
    (check-equal? #f (outline:cached b))
    (let ([o (outline:get b)])
      (check-equal? o (outline:cached b)))
    (buffers:kill! b)
    (check-equal? #f (outline:cached b))))

(test "outline:updated is called when an outline differs from the last by names, kinds or ranges, and not for an equal one"
  (let* ([b (fresh "alpha")] [kind 'function] [told '()]
         [note (lambda (buffer o) (when (eq? buffer b) (set! told (cons (names o) told))))])
    (add-sources! b (stub 'kinds (lambda (b) (outline:make-outline b (buffers:version b)
                                             (list (entry b "alpha" kind 0 5))))))
    (hooks:add! outline:updated note)
    (outline:get b)
    (outline:forget! b)
    (outline:get b)
    (check-equal? 1 (length told))
    (set! kind 'macro)
    (outline:forget! b)
    (outline:get b)
    (check-equal? 2 (length told))
    (hooks:remove! outline:updated note)))

(define (cart-outline b)
  (outline:make-outline b (buffers:version b)
    (list (outline:make-entry "top" 'function (at b 10) (at b 50) (at b 18))
          (outline:make-parent (outline:make-entry "Cart" 'class (at b 100) (at b 400) (at b 106))
            (list (outline:make-entry "add" 'method (at b 110) (at b 120) (at b 114))
                  (outline:make-entry "total" 'method (at b 120) (at b 188) (at b 124))))
          (outline:make-entry "after" 'function (at b 400) (at b 450) (at b 408)))))

(define (path-names o p) (let ([found (outline:path o p)]) (and found (map outline:entry-name found))))

(test "outline:paths names each entry by its parents' names and its own joined by /, numbering the second of one path (1), the third (2)"
  (let* ([b (fresh (make-string 500 #\x))]
         [o (outline:make-outline b (buffers:version b)
              (list (outline:make-parent (outline:make-entry "Cart" 'class (at b 0) (at b 100) (at b 0))
                      (list (outline:make-entry "total" 'method (at b 10) (at b 20) (at b 10))
                            (outline:make-entry "total" 'method (at b 30) (at b 40) (at b 30))))
                    (outline:make-entry "Cart" 'class (at b 200) (at b 300) (at b 200))
                    (outline:make-entry "Cart" 'class (at b 300) (at b 400) (at b 300))))]
         [paths (outline:paths o)] [found '()])
    (outline:walk o (lambda (e ancestors) (set! found (cons (eq-hashtable-ref paths e #f) found))))
    (check-equal? '("Cart" "Cart/total" "Cart/total (1)" "Cart (1)" "Cart (2)") (reverse found))))

(test "outline:walk visits parents before children, in order, with their ancestors outermost first"
  (let ([b (fresh (make-string 500 #\x))] [seen '()])
    (outline:walk (cart-outline b)
      (lambda (e ancestors) (set! seen (cons (cons (outline:entry-name e) (map outline:entry-name ancestors)) seen))))
    (check-equal? '(("top") ("Cart") ("add" "Cart") ("total" "Cart") ("after")) (reverse seen))))

(test "outline:path gives the entries holding a position, outermost first; a range holds its edges, and an edge two siblings share is the earlier's"
  (let* ([b (fresh (make-string 500 #\x))] [o (cart-outline b)])
    (check-equal? '("Cart" "total") (path-names o (at b 188)))
    (check-equal? '("Cart" "total") (path-names o (at b 150)))
    (check-equal? '("Cart") (path-names o (at b 300)))
    (check-equal? '() (path-names o (at b 70)))
    (check-equal? '() (path-names o (at b 5)))
    (check-equal? '("Cart" "add") (path-names o (at b 120)))
    (check-equal? '("Cart") (path-names o (at b 400)))))

(test "after edits the path follows the mapped ranges, mapping a logarithmic number of positions for each level, even 5,000 edits on"
  (let* ([b (fresh (make-string 20000 #\x))]
         [o (outline:make-outline b (buffers:version b)
              (map (lambda (k)
                     (outline:make-parent (outline:make-entry (format "f~a" k) 'function (at b (* k 16)) (at b (+ (* k 16) 15))
                                                              (at b (* k 16)))
                       (list (outline:make-entry (format "g~a" k) 'function (at b (+ (* k 16) 2)) (at b (+ (* k 16) 9))
                                                 (at b (+ (* k 16) 2))))))
                   (iota 1024)))]
         [maps 0]
         [count (lambda (next . arguments) (set! maps (+ maps 1)) (apply next arguments))])
    (buffers:replace! b (at b 0) (at b 0) "abc")
    (check-equal? '("f700" "g700") (path-names o (at b (+ (* 700 16) 3 4))))
    (do ([k 0 (+ k 1)]) ((= k 5000)) (buffers:replace! b (at b 19000) (at b 19000) "y"))
    (advice-add! buffers:map-position count)
    (advice-add! buffers:map-position-after count)
    (check-equal? '("f700" "g700") (path-names o (at b (+ (* 700 16) 3 4))))
    (advice-remove! buffers:map-position count)
    (advice-remove! buffers:map-position-after count)
    (check (<= maps 50))))

(test "outline:nest nests entries by what holds what, given in any order; equal ranges nest in the order given"
  (let* ([b (fresh (make-string 500 #\x))]
         [roots (outline:nest (list (outline:make-entry "total" 'function (at b 120) (at b 188) (at b 124))
                                    (outline:make-entry "Cart" 'class (at b 100) (at b 400) (at b 106))
                                    (outline:make-entry "outer" 'heading (at b 450) (at b 460) (at b 450))
                                    (outline:make-entry "inner" 'heading (at b 450) (at b 460) (at b 450))))])
    (check-equal? '("Cart" "outer") (map outline:entry-name roots))
    (check-equal? '("total") (map outline:entry-name (outline:entry-children (car roots))))
    (check-equal? '("inner") (map outline:entry-name (outline:entry-children (cadr roots))))))

(test "outline:make-entry refuses an empty name, an end before the start and a point outside the range"
  (check-raises assertion-violation? (outline:make-entry "" 'function 1 5 1))
  (check-raises assertion-violation? (outline:make-entry "  " 'function 1 5 1))
  (check-raises assertion-violation? (outline:make-entry "f" 'function 5 1 5))
  (check-raises assertion-violation? (outline:make-entry "f" 'function 1 5 6)))

(test "outline:make-parent refuses a child outside its parent and children out of order"
  (let ([parent (outline:make-entry "p" 'class 10 50 10)])
    (check-raises assertion-violation? (outline:make-parent parent (list (outline:make-entry "c" 'method 40 60 40))))
    (check-raises assertion-violation?
      (outline:make-parent parent (list (outline:make-entry "b" 'method 30 40 30) (outline:make-entry "a" 'method 12 20 12))))))

(test "an answer older than the buffer keeps its version, outline:map and outline:path carry it, and the next idle makes one at the buffer's version"
  (let* ([b (fresh "alpha beta")] [old (buffers:version b)] [asked 0])
    (edit! b)
    (edit! b)
    (add-sources! b (stub 'older (lambda (b)
                                 (set! asked (+ asked 1))
                                 (if (= asked 1)
                                     (outline:make-outline b old (list (outline:make-entry "beta" 'function (at b 6) (at b 10) (at b 6))))
                                     (words-outline b)))))
    (let ([o (outline:get b)])
      (check-equal? old (outline:version o))
      (check-equal? (at b 10) (outline:map o (at b 6)))
      (check-equal? '("beta") (path-names o (at b 12))))
    (outline:cached b)
    (idle!)
    (test-runner:wait-until (lambda () (= (buffers:version b) (outline:version (outline:cached b)))))
    (check-equal? '("w" "w" "alpha" "beta") (names (outline:cached b)))))

(test "a forgotten outline that was read is made again after the idle delay and outline:updated tells of it; one never read is made only when asked"
  (let* ([b (fresh "alpha")] [c (fresh "gamma")] [text "alpha"] [told '()]
         [note (lambda (buffer o) (when (eq? buffer b) (set! told (cons (names o) told))))])
    (add-sources! b (stub 'forgotten (lambda (b) (outline:make-outline b (buffers:version b)
                                             (list (outline:make-entry text 'function (at b 0) (at b 5) (at b 0)))))))
    (add-sources! c (stub 'unread words-outline))
    (hooks:add! outline:updated note)
    (outline:get b)
    (outline:get c)
    (outline:cached b)
    (set! text "omega")
    (outline:forget! b)
    (outline:forget! c)
    (idle!)
    (test-runner:wait-until (lambda () (= 2 (calls 'forgotten))))
    (check-equal? '(("omega") ("alpha")) told)
    (check-equal? 1 (calls 'unread))
    (outline:get c)
    (check-equal? 2 (calls 'unread))
    (hooks:remove! outline:updated note)))

(test "a read buffer edited is made again once, after the idle delay, and outline:updated tells of the new names"
  (test-user:show! "alpha|")
  (let ([b (views:buffer (layout:selected-view))] [told '()])
    (define (note buffer o) (when (eq? buffer b) (set! told (cons (names o) told))))
    (add-sources! b (stub 'typed words-outline))
    (hooks:add! outline:updated note)
    (outline:get b)
    (outline:cached b)
    (test-user:type! "z")
    (test-runner:wait-until (lambda () (= 2 (calls 'typed))))
    (check-equal? '(("alphaz") ("alpha")) told)
    (hooks:remove! outline:updated note)))

(test "a buffer only ever asked with outline:get is not made again at idle, while one read is"
  (test-user:show! "alpha|")
  (let ([b (views:buffer (layout:selected-view))] [read (fresh "beta")])
    (add-sources! b (stub 'asked-only words-outline))
    (add-sources! read (stub 'read words-outline))
    (outline:get b)
    (outline:get read)
    (outline:cached read)
    (edit! read)
    (test-user:type! "z")
    (test-runner:wait-until (lambda () (= 2 (calls 'read))))
    (check-equal? 1 (calls 'asked-only))))

(test "a server that becomes ready forgets the outline another source gave; after the idle delay the outline is the server's, which get gives with no edit"
  (let* ([b (fresh "alpha beta")] [ready? #f]
         [server (lambda (b) (and ready? (outline:make-outline b (buffers:version b)
                                             (list (outline:make-entry "server" 'module (at b 0) (at b 10) (at b 0))))))])
    (add-sources! b (stub 'server server) (stub 'words words-outline))
    (outline:cached b)
    (idle!)
    (test-runner:wait-until (lambda () (outline:cached b)))
    (check-equal? '("alpha" "beta") (names (outline:cached b)))
    (set! ready? #t)
    (outline:forget! b)
    (test-runner:wait-until (lambda () (equal? '("server") (names (outline:cached b)))))
    (let ([n (calls 'server)])
      (check-equal? '("server") (names (outline:get b)))
      (check-equal? n (calls 'server)))))

(test "a forget that lands while the outline is being made has it made again once that ends, Tuna having rested"
  (let* ([b (fresh "alpha")] [gate (make-gate)] [text "alpha"]
         [source (lambda (b)
                   (let ([v (buffers:version b)] [name text])
                     (wait-at! gate)
                     (outline:make-outline b v (list (outline:make-entry name 'function (at b 0) (at b 5) (at b 0))))))])
    (add-sources! b (stub 'gated source))
    (outline:cached b)
    (idle!)
    (test-runner:wait-until (lambda () (= 1 (calls 'gated))))
    (set! text "omega")
    (outline:forget! b)
    (open! gate)
    (test-runner:wait-until (lambda () (and (outline:cached b) (equal? '("omega") (names (outline:cached b))))))
    (check-equal? 2 (calls 'gated))))

(tables:define-table other-keymap)

(hooks:define-hook other-hook)

(modes:define-major-mode other-mode (keymap other-keymap) (hook other-hook))

(test "a change of major mode makes the outline stale, and a read buffer is made again at idle"
  (let* ([b (fresh "alpha")] [source (only b (stub 'mode words-outline))])
    (hooks:add! outline:sources source)
    (outline:get b)
    (outline:get b)
    (check-equal? 1 (calls 'mode))
    (outline:cached b)
    (modes:set-major-mode other-mode b)
    (idle!)
    (test-runner:wait-until (lambda () (= 2 (calls 'mode))))
    (outline:get b)
    (check-equal? 2 (calls 'mode))
    (hooks:remove! outline:sources source)))

(test "adding or removing a source makes every outline made before stale"
  (let* ([b (fresh "alpha")] [source (only b (stub 'source-list words-outline))]
         [other (lambda (x) #f)])
    (hooks:add! outline:sources source)
    (outline:get b)
    (hooks:add! outline:sources other 5)
    (outline:get b)
    (check-equal? 2 (calls 'source-list))
    (hooks:remove! outline:sources other)
    (outline:get b)
    (check-equal? 3 (calls 'source-list))
    (hooks:remove! outline:sources source)))

(test "outline:cached of a buffer with no outline gives #f, and a first outline is made at the next idle"
  (let ([b (fresh "alpha")])
    (add-sources! b (stub 'first-idle words-outline))
    (check-equal? #f (outline:cached b))
    (idle!)
    (test-runner:wait-until (lambda () (outline:cached b)))
    (check-equal? '("alpha") (names (outline:cached b)))))

(test "outline:make-outline refuses a version the buffer has not reached"
  (let ([b (fresh "alpha")])
    (check-raises assertion-violation? (outline:make-outline b (+ (buffers:version b) 1) '()))))
