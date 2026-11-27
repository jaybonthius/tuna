#!tuna
(import (document) (buffers) (views) (layout) (layout-split) (web) (haml) (http) (scroll-report) (tables) (timers)
  (rename (only (chezscheme) collect-request-handler) (collect-request-handler chez:collect-request-handler)))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (ns-per-op count run)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i count)) (run i))
             (/ (- (now-ns) start) (exact->inexact count))))
         (iota 9))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(buffers:define-layer syntax (priority 10))

(define (draw-paragraph node view) (haml (:div.p (views:draw-children view node))))

(buffers:define-kind code (content nodes))
(buffers:define-kind paragraph (draw draw-paragraph))

(define (code-line k)
  (format "  (define (name-~a x) (+ x ~a)) ; note\n" (mod k 997) (mod k 89)))

(define (spans-of-line start line)
  (let loop ([i 0] [acc '()] [n 0])
    (cond
      [(or (= n 4) (>= (+ i 6) (string-length line))) (reverse acc)]
      [(char=? (string-ref line i) #\space) (loop (+ i 1) acc n)]
      [else
       (let ([end (let scan ([j i]) (if (or (= j (string-length line)) (char=? (string-ref line j) #\space)) j (scan (+ j 1))))])
         (loop end (cons (list (+ start i) (+ start end) (if (even? n) '((face . keyword)) '((face . name)))) acc) (+ n 1)))])))

(define (text-buffer name lines)
  (let* ([texts (map code-line (iota lines))]
         [b (buffers:make name (apply string-append texts))])
    (let loop ([texts texts] [at 1] [spans '()])
      (if (null? texts)
          (buffers:set-spans! (buffers:layer b syntax) 0 (document:length (buffers:document b)) (reverse spans))
          (loop (cdr texts) (+ at (string-length (car texts)))
                (append (reverse (spans-of-line at (car texts))) spans))))
    b))

(define (node-buffer name lines)
  (buffers:make name (apply code '() (map (lambda (k) (paragraph '() (code-line k))) (iota lines)))))

(define (show-layout! b views)
  (layout:reset-layout)
  (let ([v (layout:selected-view)])
    (layout:switch-to-buffer b)
    (when (= views 3)
      (let ([right (layout-split:split-view! v (layout-split:direction row))])
        (layout:switch-to-buffer b)
        (layout-split:split-view! right (layout-split:direction column))))
    (for-each
      (lambda (v)
        (let* ([doc (buffers:document b)]
               [middle (document:line-start doc (quotient (document:line doc (document:length doc)) 2))])
          (views:set-point! v (+ middle 4))
          (views:scroll-to! v middle (views:align center))))
      (layout:views))
    (layout:select! v)))

;; Typing then deleting keeps every screen different and the buffer the
;; same size.
(define (edit! i)
  (let* ([v (layout:selected-view)] [b (views:buffer v)] [p (views:point v)])
    (if (even? i)
        (begin (buffers:replace! b p p "x") (views:set-point! v (+ p 1)))
        (buffers:replace! b (- p 1) p ""))))

(define (screen-bytes client) (bytevector-length (html->bytevector (layout:screen client))))

(define (lines-drawn client) (length (scroll-report:lines-drawn (html->string (layout:screen client)))))

(define (wait-for done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (timers:sleep 0.01)
      (loop (+ n 1)))))

;; The pages confirm no screen, so that their work does not share the
;; CPUs with what drawing costs the main thread.
(define (connect-pages! n)
  (let ([before (length (web:clients))])
    (for-each (lambda (i) (http:connect! (http:page))) (iota n))
    (wait-for (lambda () (= (length (web:clients)) (+ before n))))))

(define (report! v client height)
  (let ([top (document:line (buffers:document (views:buffer v)) (views:top v client))])
    ((tables:ref web:input-handlers "scroll") client (scroll-report:make v client top height #t))))

(define (measure-all!)
  (for-each
    (lambda (client k)
      (let ([height (if (even? k) 990 800)] [vs (layout:views)])
        (for-each
          (lambda (v i)
            (let ([h (if (and (= (length vs) 3) (> i 0)) (quotient height 2) height)])
              (report! v client h)
              (report! v client h)))
          vs (iota (length vs)))))
    (web:clients) (iota (length (web:clients)))))

(define (draw-cost client)
  (ns-per-op 200
    (lambda (i)
      (edit! i)
      (web:send-screen! client (layout:screen client) "text - Tuna"))))

(define (batch-cost client)
  (ns-per-op 200
    (lambda (i)
      (edit! i)
      (batch-ended))))

(define (case! name b views)
  (show-layout! b views)
  (measure-all!)
  (let ([client (car (web:clients))])
    (printf "~a: ~a lines drawn, ~a bytes a screen\n" name (lines-drawn client) (screen-bytes client))
    (show (string-append "draw-" name) (draw-cost client))))

;; Every thread stops for a full collection, since collect alone refuses
;; while other threads run.
(define (collect-fully)
  (parameterize ([chez:collect-request-handler (lambda () (collect (collect-maximum-generation)))])
    (collect-rendezvous)))

(define (run)
  (http:use-port! (lambda () (web:port)))
  (http:wait-for-server)
  (let ([text (text-buffer "text" 22000)] [nodes (node-buffer "nodes" 22000)])
    (collect-fully)
    (connect-pages! 1)
    (show-layout! text 1)
    (measure-all!)
    (let ([client (car (web:clients))])
      (show "batch-one-client" (batch-cost client))
      (show "batch-unchanged" (ns-per-op 200 (lambda (i) (batch-ended))))
      (connect-pages! 1)
      (measure-all!)
      (show "batch-two-clients" (batch-cost client))
      (connect-pages! 2)
      (measure-all!)
      (show "batch-four-clients" (batch-cost client)))
    (case! "text-one-view" text 1)
    (case! "text-three-views" text 3)
    (case! "nodes-one-view" nodes 1)
    (case! "nodes-three-views" nodes 3)))
