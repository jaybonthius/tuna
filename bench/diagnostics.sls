#!tuna
(import (buffers) (document) (diagnostics) (diagnostics-list) (status-line) (layout) (web) (haml) (options))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define (ns-per-op n thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i n)) (thunk))
             (/ (- (now-ns) start) (exact->inexact n))))
         (iota 9))))

(define lines 10000)

(define (ten-thousand-lines name)
  (buffers:make name
    (apply string-append
      (map (lambda (i) (format "line ~a with some words in it\n" i)) (iota lines)))))

(define (document-at-cost back)
  (let ([b (ten-thousand-lines (format "versions-~a" back))])
    (let ([middle (document:line-start (buffers:document b) (quotient lines 2))])
      (do ([i 0 (fx+ i 1)]) ((fx= i back)) (buffers:replace! b middle middle "x")))
    (let ([v (fx- (buffers:version b) back)])
      (ns-per-op 20 (lambda () (buffers:document-at b v))))))

(define (marked-buffer name n)
  (let* ([b (ten-thousand-lines name)] [source (diagnostics:make-source)]
         [ds (map (lambda (i)
                    (diagnostics:make-diagnostic (cons (fx+ 1 (fx* i (quotient lines n))) 5) (cons (fx+ 1 (fx* i (quotient lines n))) 9)
                      (if (even? i) (diagnostics:severity warning) (diagnostics:severity error)) "a problem"))
                  (iota n))])
    (buffers:with-buffer b (options:set-local! diagnostics:mode #t))
    (values b source ds)))

(define (report-cost n)
  (let-values ([(b source ds) (marked-buffer (format "report-~a" n) n)])
    (/ (ns-per-op 5 (lambda () (diagnostics:report! source b ds))) 1000000.0)))

;; A keystroke types a character and deletes it, so the deletion looks
;; for emptied diagnostics too.
(define (keystroke-cost n)
  (let-values ([(b source ds) (marked-buffer (format "keystroke-~a" n) n)])
    (diagnostics:report! source b ds)
    (let ([p (document:line-start (buffers:document b) (quotient lines 2))])
      (ns-per-op 200 (lambda () (buffers:replace! b p p "x") (buffers:replace! b p (fx+ p 1) ""))))))

(define (status-line-cost n)
  (let-values ([(b source ds) (marked-buffer (format "status-~a" n) n)])
    (diagnostics:report! source b ds)
    (layout:switch-to-buffer b)
    (let ([v (layout:selected-view)] [client (web:add-client! (fx+ n 1))])
      (ns-per-op 200 (lambda () (html->bytevector (status-line:draw v client)))))))

(define (run)
  (for-each (lambda (back) (show (format "document-at-~a-us" back) (/ (document-at-cost back) 1000.0))) '(1 10 1000))
  (show "report-2000-ms" (report-cost 2000))
  (show "keystroke-0-us" (/ (keystroke-cost 0) 1000.0))
  (show "keystroke-2000-us" (/ (keystroke-cost 2000) 1000.0))
  (show "status-line-0-us" (/ (status-line-cost 0) 1000.0))
  (show "status-line-2000-us" (/ (status-line-cost 2000) 1000.0)))
