(import (hooks) (options) (tables) (timers))
(import (tuna) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin search)

(define client (web:add-client! 1))

(define (view) (layout:selected-view))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define forward (search:direction forward))
(define backward (search:direction backward))

;; A buffer holding text, and a match shown as its range and text.
(define (text-buffer name text) (buffers:make name text))

(define (span b m)
  (and m (list (search:match-start m) (search:match-end m)
               (buffers:text-between (buffers:document b) (search:match-start m) (search:match-end m)))))

(define (find-in b q position direction . range)
  (span b (apply search:find b q position direction range)))

(define (end-of b) (document:length (buffers:document b)))

;; Every match forward from the start, by repeated finds.
(define (all-in b q . range)
  (let ([start (if (pair? range) (car range) 0)])
    (let loop ([p start] [acc '()])
      (let ([m (apply search:find b q p forward range)])
        (if m
            (loop (if (= (search:match-start m) (search:match-end m)) (+ (search:match-end m) 1) (search:match-end m))
                  (cons (span b m) acc))
            (reverse acc))))))

;; A scan's matches once it is done.
(define (scanned b q . range)
  (let* ([done #f]
         [s (apply search:scan b q (if (pair? range) (car range) 0) (if (pair? range) (cadr range) (end-of b))
                   (if (pair? range) (car range) 0) (lambda (s) (when (search:scan-done? s) (set! done #t)))
                   (if (and (pair? range) (pair? (cddr range))) (cddr range) '()))])
    (let wait ([n 0]) (unless (or done (= n 500)) (timers:sleep 0.01) (wait (+ n 1))))
    s))

(define (scan-spans b s)
  (map (lambda (m) (span b m)) (search:scan-matches s 0 (end-of b))))
(import (console))
