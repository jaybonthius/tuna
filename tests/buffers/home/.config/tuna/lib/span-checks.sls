;; Every operation of the model is a pass over a plain list, so that it is
;; plainly right. A few spans are long, so that lookups that rely on the
;; longest span reach far back.
(library (span-checks)
  (export span-checks)
  (import (chezscheme) (buffers spans))

  (define (cut x s b) (cond [(<= x s) x] [(>= x b) (- x (- b s))] [else s]))

  (define (model-map spans s r i front? rear? evaporate?)
    (let ([b (+ s r)])
      (fold-right
        (lambda (x acc)
          (let ([a (cut (car x) s b)] [e (cut (cadr x) s b)])
            (if (and evaporate? (= a e) (< (car x) (cadr x)))
                acc
                (cons (if (= i 0)
                          (list a e (caddr x))
                          (list (cond [(> a s) (+ a i)] [(< a s) a] [front? a] [(or (< a e) rear?) (+ a i)] [else a])
                                (cond [(> e s) (+ e i)] [(and (= e s) rear?) (+ e i)] [else e])
                                (caddr x)))
                      acc))))
        '() spans)))

  (define (model-split spans s i)
    (fold-right
      (lambda (x acc)
        (let ([a (car x)] [e (cadr x)] [v (caddr x)])
          (cond
            [(>= a s) (cons (list (+ a i) (+ e i) v) acc)]
            [(> e s) (cons* (list a s v) (list (+ s i) (+ e i) v) acc)]
            [else (cons x acc)])))
      '() spans))

  (define (model-taking spans s r front? rear? travels?)
    (let* ([b (+ s r)]
           [near (list-sort span<? (filter (lambda (x) (and (>= (cadr x) s) (<= (car x) b))) spans))])
      (if travels?
          (let ([before (if rear? (filter (lambda (x) (and (< (cut (car x) s b) s) (>= (cut (cadr x) s b) s))) near) '())])
            (cond
              [(pair? before) before]
              [front? (filter (lambda (x) (and (<= (cut (car x) s b) s) (> (cut (cadr x) s b) s))) near)]
              [else '()]))
          (filter (lambda (x)
                    (let* ([moved (car (model-map (list x) s r 1 front? rear? #f))])
                      (and (<= (car moved) s) (>= (cadr moved) (+ s 1)))))
                  near))))

  (define (overlaps? a e start end)
    (if (< start end)
        (if (< a e) (and (< a end) (< start e)) (and (<= start a) (< a end)))
        (if (< a e) (and (<= a start) (< start e)) (= a start))))

  (define (span<? x y)
    (or (< (car x) (car y))
        (and (= (car x) (car y))
             (or (< (cadr x) (cadr y))
                 (and (= (cadr x) (cadr y)) (< (caddr x) (caddr y)))))))

  (define (normal spans) (list-sort span<? spans))

  (define failures 0)
  (define checks 0)

  (define (check! what expected actual)
    (set! checks (+ checks 1))
    (unless (equal? (normal expected) (normal actual))
      (set! failures (+ failures 1))
      (when (< failures 10)
        (printf "~a: expected ~s, got ~s\n" what (normal expected) (normal actual)))))

  (define (sorted-by-start? spans)
    (or (null? spans) (null? (cdr spans))
        (and (<= (car (car spans)) (car (cadr spans))) (sorted-by-start? (cdr spans)))))

  (define (run rounds size)
    (let ([store (make-spans)] [model '()] [next 0])
      (define (position) (random size))
      (do ([k 0 (+ k 1)]) ((= k rounds))
        (case (random 9)
          [(0 1 2)
           (let* ([a (position)] [e (min size (+ a (random (if (= (random 30) 0) (quotient size 3) 6))))])
             (set! next (+ next 1))
             (spans-add! store a e next)
             (set! model (cons (list a e next) model)))]
          [(3)
           (let* ([s (position)] [r (random 4)] [i (random 3)]
                  [front? (= (random 2) 0)] [rear? (= (random 2) 0)] [evaporate? (= (random 2) 0)])
             (spans-map! store s r i front? rear? evaporate?)
             (set! model (model-map model s r i front? rear? evaporate?)))]
          [(4)
           (let ([s (position)] [i (+ 1 (random 3))])
             (spans-split! store s i)
             (set! model (model-split model s i)))]
          [(5)
           (let* ([lo (position)] [hi (+ lo (random 5))])
             (check! "take" (filter (lambda (x) (and (>= (cadr x) lo) (<= (car x) hi) (odd? (caddr x)))) model)
                     (spans-take! store lo hi (lambda (a e v) (odd? v))))
             (set! model (remp (lambda (x) (and (>= (cadr x) lo) (<= (car x) hi) (odd? (caddr x)))) model)))]
          [(6)
           (let* ([start (position)] [end (+ start (random 5))] [found (spans-overlapping store start end)])
             (check! "overlapping" (filter (lambda (x) (overlaps? (car x) (cadr x) start end)) model) found)
             (unless (sorted-by-start? found) (check! "overlapping by start" '() (list found))))]
          [(7)
           (let* ([s (position)] [r (random 3)] [front? (= (random 2) 0)] [rear? (= (random 2) 0)] [travels? (= (random 2) 0)])
             (check! "taking" (model-taking model s r front? rear? travels?)
                     (spans-taking store s r front? rear? travels?)))]
          [else
           (let* ([lo (position)] [hi (+ lo (random 3))])
             (check! "touching" (filter (lambda (x) (and (>= (cadr x) lo) (<= (car x) hi))) model)
                     (spans-touching store lo hi)))])
        (check! "all" model (spans-all store))
        (unless (sorted-by-start? (spans-all store)) (check! "all by start" '() (list (spans-all store)))))))

  (define (span-checks seed)
    (random-seed seed)
    (set! failures 0)
    (set! checks 0)
    (run 3000 60)
    (run 3000 400)
    (run 8000 3000)
    (list checks failures)))
