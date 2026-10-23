(import :std/test
        :tuna/lib/plain-data)
(export plain-data-test)

(defclass ring ((other : :t)) final: #t)

(def (raises? thunk)
  (with-catch (lambda (e) #t) (lambda () (thunk) #f)))

(def plain-data-test
  (test-suite "tuna/lib/plain-data"
    (test-case "plain-equal?: equal? for plain data, the same object otherwise, even cyclic"
      (let ((a (ring other: #f)) (b (ring other: #f)) (c (ring other: #f)) (d (ring other: #f)))
        (set! (ring-other a) b) (set! (ring-other b) a)
        (set! (ring-other c) d) (set! (ring-other d) c)
        (check (plain-equal? [1 "x" #(a 2)] [1 "x" #(a 2)]) => #t)
        (check (plain-equal? [1 "x"] [1 "y"]) => #f)
        (check (plain-equal? a a) => #t)
        (check (plain-equal? a c) => #f)
        (check (plain-equal? [a] [a]) => #f)
        (check (plain-value? [1 'x "s" #\c #t []]) => #t)
        (check (plain-value? [1 a]) => #f)))

    (test-case "check-plain-data! fails on objects only in test mode"
      (let (object (ring other: #f))
        (set-plain-data-checking! #f)
        (check (raises? (lambda () (check-plain-data! "input" object))) => #f)
        (set-plain-data-checking! #t)
        (check (raises? (lambda () (check-plain-data! "input" object))) => #t)
        (check (raises? (lambda () (check-plain-data! "input" [1 "two" #(three)]))) => #f)
        (set-plain-data-checking! #f)))))
