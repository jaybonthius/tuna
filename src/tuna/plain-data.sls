(library (tuna plain-data)
  (export plain-data? plain-data-copy)
  (import (chezscheme))

  (define (plain-atom? v)
    (or (number? v) (char? v) (string? v) (symbol? v) (boolean? v) (bytevector? v) (null? v)))

  ;; What has been walked stays marked done, not just what is being walked:
  ;; otherwise shared structure is walked once per path to it, which can
  ;; grow exponentially with its depth.
  (define (plain-data? v)
    (if (or (pair? v) (vector? v))
        (let ([marks (make-eq-hashtable)])
          (define (walk v)
            (cond
              [(pair? v) (walk-list v '())]
              [(vector? v)
               (case (eq-hashtable-ref marks v #f)
                 [(done) #t]
                 [(walking) #f]
                 [else
                  (eq-hashtable-set! marks v 'walking)
                  (let ([n (vector-length v)])
                    (let loop ([i 0])
                      (cond
                        [(fx= i n) (eq-hashtable-set! marks v 'done) #t]
                        [(walk (vector-ref v i)) (loop (fx+ i 1))]
                        [else #f])))])]
              [else (plain-atom? v)]))
          (define (walk-list p spine)
            (cond
              [(pair? p)
               (case (eq-hashtable-ref marks p #f)
                 [(done) (finish spine)]
                 [(walking) #f]
                 [else
                  (eq-hashtable-set! marks p 'walking)
                  (and (walk (car p)) (walk-list (cdr p) (cons p spine)))])]
              [else (and (walk p) (finish spine))]))
          (define (finish spine)
            (for-each (lambda (p) (eq-hashtable-set! marks p 'done)) spine)
            #t)
          (walk v))
        (plain-atom? v)))

  ;; Another thread may read the copy while the caller goes on changing
  ;; the original, so the copy shares no mutable object with it. Shared
  ;; structure is copied once, or the copy could grow exponentially.
  (define (plain-data-copy who v)
    (let ([copies (make-eq-hashtable)] [walking (list 'walking)])
      (define (not-plain) (assertion-violation who "not plain data" v))
      (define (copy v)
        (cond
          [(pair? v) (copy-list v '())]
          [(vector? v)
           (let ([c (eq-hashtable-ref copies v #f)])
             (cond
               [(eq? c walking) (not-plain)]
               [c c]
               [else
                (eq-hashtable-set! copies v walking)
                (let ([c (vector-map copy v)])
                  (eq-hashtable-set! copies v c)
                  c)]))]
          [(string? v) (if (immutable-string? v) v (shared v string->immutable-string))]
          [(bytevector? v) (if (immutable-bytevector? v) v (shared v bytevector->immutable-bytevector))]
          [(plain-atom? v) v]
          [else (not-plain)]))
      (define (shared v make)
        (or (eq-hashtable-ref copies v #f)
            (let ([c (make v)])
              (eq-hashtable-set! copies v c)
              c)))
      ;; Along the cdrs by iteration, so a long list needs no deep recursion.
      (define (copy-list p spine)
        (let ([c (and (pair? p) (eq-hashtable-ref copies p #f))])
          (cond
            [(eq? c walking) (not-plain)]
            [(and (pair? p) (not c))
             (eq-hashtable-set! copies p walking)
             (copy-list (cdr p) (cons (cons p (copy (car p))) spine))]
            [else
             (fold-left
               (lambda (tail walked)
                 (let ([c (cons (cdr walked) tail)])
                   (eq-hashtable-set! copies (car walked) c)
                   c))
               (or c (copy p))
               spine)])))
      (copy v))))
