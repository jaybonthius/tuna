(import (tuna) (tuna plugins) (tuna eval) (document) (web) (disk))
(use-plugin layout)
(use-plugin modes)
(use-plugin auto-mode)
(use-plugin editing)
(use-plugin files)
(use-plugin prog
  (config
    (add-hook! prog:mode-hook
      (lambda () (set-option-local! files:require-final-newline #t)))))
(use-plugin chez-scheme
  (config
    (table-set! auto-mode:file-names "ms" chez-scheme:mode)
    (keys:bind! chez-scheme:keymap "C-c C-u" editing:upcase-region)))

(define (text b) (document:text (buffers:document b)))

(define (local option b) (buffers:with-buffer b (option)))

(define (scheme-buffer name content)
  (let ([b (buffers:make name content)])
    (modes:set-major-mode chez-scheme:mode b)
    b))

;; Highlighting runs in a job, so a test waits until its spans have not
;; changed for a while.
(define (settle b)
  (let loop ([n 0] [same 0] [last #f])
    (let ([now (list (buffers:spans (buffers:layer b syntax-highlighting:faces) 0 (document:length (buffers:document b)))
                     (buffers:spans (buffers:layer b syntax:brackets) 0 (document:length (buffers:document b))))])
      (unless (or (= same 15) (= n 500))
        (sleep-for 0.02)
        (loop (+ n 1) (if (equal? now last) (+ same 1) 0) now)))))

(define (faces b)
  (settle b)
  (map (lambda (s) (list (document:text (buffers:document b) (car s) (cadr s)) (cdr (assq 'face (caddr s)))))
       (buffers:spans (buffers:layer b syntax-highlighting:faces) 0 (document:length (buffers:document b)))))

(define (face-of b word)
  (let ([found (assoc word (faces b))])
    (and found (cadr found))))

(define (brackets b)
  (settle b)
  (buffers:spans (buffers:layer b syntax:brackets) 0 (document:length (buffers:document b))))

(define (after b string)
  (let* ([all (text b)] [n (string-length string)])
    (let loop ([i 0])
      (if (string=? (substring all i (+ i n)) string)
          (document:position (buffers:document b) (+ i n) (document:unit characters))
          (loop (+ i 1))))))

(define (before b string)
  (let* ([all (text b)] [n (string-length string)])
    (let loop ([i 0])
      (if (string=? (substring all i (+ i n)) string)
          (- (document:position (buffers:document b) (+ i 1) (document:unit characters)) 1)
          (loop (+ i 1))))))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
