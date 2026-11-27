#!tuna
(import (isearch) (search) (search-bench) (buffers) (views) (layout) (keys) (web) (timers))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs) (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (press! client . keys)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) (lambda () (for-each (lambda (k) (keys:press! client k)) keys)))))

;; With a pause after DEL, the scan it starts has handed back its copy of
;; the text, as between keys typed at a person's pace.
(define (key-to-screen-ms client keys runs pause)
  (let ([view (layout:selected-view)] [last-key (car (last-pair keys))])
    (views:set-point! view 1)
    (apply press! client "C-M-s" keys)
    (let ([times (map (lambda (k)
                        (press! client "DEL")
                        (timers:sleep pause)
                        (collect-rendezvous)
                        (let ([start (now-ns)])
                          (press! client last-key)
                          (views:draw view client)
                          (/ (- (now-ns) start) 1e6)))
                      (iota runs))])
      (guard (c [(cancelled? c) #f]) (press! client "ESC"))
      (median times))))

(define (repeat-far-ms client runs)
  (let* ([b (buffers:make "isearch-far" (string-append "needle\n" (search-bench:sample 'code 100000000) "needle\n"))]
         [view (layout:selected-view)])
    (layout:switch-to-buffer b)
    (median
      (map (lambda (k)
             (views:set-point! view 1)
             (press! client "C-s" "n" "e" "e" "d" "l" "e")
             (let wait () (unless (search:scan-done? (isearch:search-scan (isearch:current client))) (timers:sleep 0.01) (wait)))
             (collect-rendezvous)
             (let ([start (now-ns)])
               (press! client "C-s")
               (views:draw view client)
               (let ([ms (/ (- (now-ns) start) 1e6)])
                 (press! client "RET")
                 ms)))
           (iota runs)))))

(define (keys-of text) (map (lambda (c) (string c)) (string->list text)))

(define (run)
  (let ([client (web:add-client! 1)]
        [code (search-bench:buffer-of (search-bench:sample 'code 100000000))]
        [cjk (search-bench:buffer-of (search-bench:sample 'cjk 100000000))])
    (layout:switch-to-buffer code)
    (printf "isearch-failing-regexp-100mb ~,3f\n" (key-to-screen-ms client (keys-of "zebra-qux") 3 0))
    (printf "isearch-failing-regexp-paced-100mb ~,3f\n" (key-to-screen-ms client (keys-of "zebra-qux") 3 0.5))
    (printf "isearch-bref-100mb ~,3f\n" (key-to-screen-ms client (keys-of "\\Bref") 3 0))
    (layout:switch-to-buffer cjk)
    (printf "isearch-words-japanese-100mb ~,3f\n" (key-to-screen-ms client (keys-of "\\b\\w+-\\w+\\b") 3 0))
    (printf "isearch-repeat-far-100mb ~,3f\n" (repeat-far-ms client 3))))
