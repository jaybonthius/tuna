#!tuna
(import (buffers) (document) (modes) (hooks) (tables) (outline))

(tables:define-table keymap "Keys in toy buffers.")
(hooks:define-hook mode-hook "Called in each toy buffer.")
(modes:define-major-mode mode (keymap keymap) (hook mode-hook))

(define %asked (make-weak-eq-hashtable))

(define (asked b) (eq-hashtable-ref %asked b 0))

(define (%lines text)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i (string-length text)) (reverse (if (< start i) (cons (cons start i) acc) acc))]
      [(char=? (string-ref text i) #\newline) (loop (+ i 1) (+ i 1) (cons (cons start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (%indent text start end)
  (let loop ([i start]) (if (and (< i end) (char=? (string-ref text i) #\space)) (loop (+ i 1)) (- i start))))

;; Each line "KIND NAME" of a toy buffer is an entry of that kind, whose
;; range runs to the end of the last line after it indented further, so
;; those lines' entries are its children. A file buffer's text starts one
;; position in.
(define (source b)
  (and (eq? (modes:major-mode b) mode)
       (begin
         (eq-hashtable-update! %asked b (lambda (n) (+ n 1)) 0)
         (let* ([text (document:text (buffers:document b))] [lines (%lines text)])
           (outline:make-outline b (buffers:version b)
             (outline:nest
               (let loop ([ls lines] [acc '()])
                 (if (null? ls)
                     (reverse acc)
                     (let* ([start (caar ls)] [end (cdar ls)] [indent (%indent text start end)]
                            [words (let split ([i (+ start indent)] [from (+ start indent)] [found '()])
                                     (cond
                                       [(= i end) (reverse (if (< from i) (cons (cons from i) found) found))]
                                       [(char=? (string-ref text i) #\space)
                                        (split (+ i 1) (+ i 1) (if (< from i) (cons (cons from i) found) found))]
                                       [else (split (+ i 1) from found)]))]
                            [last-end (let reach ([rest (cdr ls)] [reached end])
                                        (if (and (pair? rest) (> (%indent text (caar rest) (cdar rest)) indent))
                                            (reach (cdr rest) (cdar rest))
                                            reached))])
                       (loop (cdr ls)
                             (if (= (length words) 2)
                                 (cons (outline:make-entry (substring text (caadr words) (cdadr words))
                                                           (string->symbol (substring text (caar words) (cdar words)))
                                                           (+ 1 start indent) (+ 1 last-end) (+ 1 (caadr words)))
                                       acc)
                                 acc)))))))))))

(hooks:add! outline:sources source)
