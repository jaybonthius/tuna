(library (tuna plain-data)
  (export plain-data?)
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
        (plain-atom? v))))
