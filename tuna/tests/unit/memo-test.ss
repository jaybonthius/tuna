(import :std/error
        :std/test
        :tuna/lib/memo)
(export memo-test)

;; Draws per key, since the last reset.
(def draws (make-hash-table))

(def (drawn key) (hash-ref draws key 0))

(def (draw! key value)
  (hash-update! draws key (lambda (n) (+ n 1)) 0)
  value)

;; Draw a parent piece reading A, holding a child piece reading B; the
;; value lists both.
(def (parent a b)
  (memo 'parent []
        (lambda (inputs)
          (record-read! a)
          (draw! 'parent (list 'parent (memo 'child [] (lambda (inputs) (record-read! b) (draw! 'child 'child))))))))

(def (reset!)
  (hash-clear! draws)
  (set-memo-checking! #f))

(def (raises? thunk)
  (with-catch (lambda (e) #t) (lambda () (thunk) #f)))

(defclass ring ((other : :t)) final: #t)

(def memo-test
  (test-suite "memo: pieces drawn again only when what they read changed"
    (test-case "a piece is reused while its sources are unchanged, and drawn again after a change"
      (reset!)
      (let ((cache (new-memo-cache)) (s (new-source)))
        (def (pass) (call-with-memo-pass cache #f (lambda () (memo 'p [] (lambda (inputs) (record-read! s) (draw! 'p 1))))))
        (pass) (pass)
        (check (drawn 'p) => 1)
        (source-changed! s)
        (pass)
        (check (drawn 'p) => 2)))
    (test-case "inputs compared with equal? decide reuse"
      (reset!)
      (let (cache (new-memo-cache))
        (def (pass inputs) (call-with-memo-pass cache #f (lambda () (memo 'p inputs (lambda (in) (draw! 'p in))))))
        (check (pass [1 "a"]) => [1 "a"])
        (pass [1 "a"])
        (check (drawn 'p) => 1)
        (check (pass [2 "a"]) => [2 "a"])
        (check (drawn 'p) => 2)))
    (test-case "a child's change draws its parent again; the unchanged child of a reused parent stays kept"
      (reset!)
      (let ((cache (new-memo-cache)) (a (new-source)) (b (new-source)))
        (def (pass) (call-with-memo-pass cache #f (lambda () (parent a b))))
        (pass)
        (source-changed! b)
        (pass)
        (check [(drawn 'parent) (drawn 'child)] => [2 2])
        ;; Reused whole, then the parent alone changes: the child, not
        ;; visited by the reused pass, was kept.
        (pass)
        (source-changed! a)
        (pass)
        (check [(drawn 'parent) (drawn 'child)] => [3 2])
        (check (memo-cache-size cache) => 2)))
    (test-case "a piece without per-client reads is shared; one with them belongs to its client"
      (reset!)
      (let ((cache (new-memo-cache)) (shared (new-source)) (measured (new-source per-client?: #t)))
        (def (pass c)
          (call-with-memo-pass cache c
            (lambda ()
              (list (memo 'shared [] (lambda (inputs) (record-read! shared) (draw! 'shared 's)))
                    (memo 'own [] (lambda (inputs) (record-read! measured) (draw! 'own 'o)))))))
        (pass 'a) (pass 'b) (pass 'a) (pass 'b)
        (check [(drawn 'shared) (drawn 'own)] => [1 2])
        (check (memo-cache-size cache) => 3)
        (memo-forget-client! cache 'a)
        (check (memo-cache-size cache) => 2)
        (memo-forget-client! cache 'b)
        (check (memo-cache-size cache) => 0)))
    (test-case "pieces a client's last pass did not use are forgotten"
      (reset!)
      (let (cache (new-memo-cache))
        (call-with-memo-pass cache #f (lambda () (memo 'x [] (lambda (inputs) 1)) (memo 'y [] (lambda (inputs) 2))))
        (check (memo-cache-size cache) => 2)
        (call-with-memo-pass cache #f (lambda () (memo 'x [] (lambda (inputs) 1))))
        (check (memo-cache-size cache) => 1)))
    (test-case "a pass that raises keeps nothing new"
      (reset!)
      (let (cache (new-memo-cache))
        (check (raises? (lambda () (call-with-memo-pass cache #f (lambda () (memo 'x [] (lambda (inputs) 1)) (error "no")))))
               => #t)
        (check (memo-cache-size cache) => 0)))
    (test-case "test mode: a duplicate key, a write while drawing, and objects in inputs fail"
      (reset!)
      (set-memo-checking! #t)
      (let ((cache (new-memo-cache)) (s (new-source)))
        (check (raises? (lambda () (call-with-memo-pass cache #f (lambda () (memo 'k [] (lambda (i) 1)) (memo 'k [] (lambda (i) 2))))))
               => #t)
        (check (raises? (lambda () (call-with-memo-pass cache #f (lambda () (memo 'w [] (lambda (i) (source-changed! s))))))) => #t)
        (check (raises? (lambda () (call-with-memo-pass cache #f (lambda () (check-not-drawing! 'test))))) => #t)
        (check (raises? (lambda () (call-with-memo-pass cache #f (lambda () (memo 'o [(ring other: #f)] (lambda (i) 1)))))) => #t)
        (check (call-with-memo-pass cache #f (lambda () (memo 'fine [1 'a "b" #\c [2.5]] (lambda (i) 3)))) => 3)
        (source-changed! s)
        (check (memo-drawing?) => #f)))
    (test-case "test mode: drawing from a value not read through a source fails the double render"
      (reset!)
      (set-memo-checking! #t)
      (let ((cache (new-memo-cache)) (hidden 1))
        (def (pass) (call-with-memo-pass cache #f (lambda () (memo 'p [] (lambda (inputs) hidden)))))
        (check (pass) => 1)
        (set! hidden 2)
        (check (raises? pass) => #t)))
    (test-case "the draw observer sees the pieces drawn, not those reused or drawn from scratch"
      (reset!)
      (set-memo-checking! #t)
      (let ((cache (new-memo-cache)) (a (new-source)) (b (new-source)) (seen []))
        (def (pass)
          (set! seen [])
          (parameterize ((current-memo-draw-observer (lambda (key) (set! seen (cons key seen)))))
            (call-with-memo-pass cache #f (lambda () (parent a b))))
          (reverse seen))
        (check (pass) => '(parent child))
        (check (pass) => '())
        (source-changed! b)
        (check (pass) => '(parent child))
        (source-changed! a)
        (check (pass) => '(parent)))
      (set-memo-checking! #f))

    (test-case "plain-equal?: equal? for plain data, the same object otherwise, even cyclic"
      (reset!)
      (let ((a (ring other: #f)) (b (ring other: #f)) (c (ring other: #f)) (d (ring other: #f)))
        (set! (ring-other a) b) (set! (ring-other b) a)
        (set! (ring-other c) d) (set! (ring-other d) c)
        (check (plain-equal? [1 "x" #(a 2)] [1 "x" #(a 2)]) => #t)
        (check (plain-equal? [1 "x"] [1 "y"]) => #f)
        (check (plain-equal? a a) => #t)
        (check (plain-equal? a c) => #f)
        (check (plain-equal? [a] [a]) => #f)
        (check (plain-value? [1 'x "s" #\c #t []]) => #t)
        (check (plain-value? [1 a]) => #f)))))
