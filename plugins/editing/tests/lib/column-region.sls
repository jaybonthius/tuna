#!tuna
(import (buffers) (document) (views) (kill-ring))

(define chars (document:unit characters))

(define (%column doc position)
  (- (document:offset doc position chars)
     (document:offset doc (document:line-start doc (document:line doc position)) chars)))

(define (%line-end doc line)
  (let ([last (document:line doc (- (document:length doc) 1))])
    (if (< line last)
        (- (document:line-start doc (+ line 1)) 1)
        (- (document:length doc) 1))))

(define (ranges region-ranges view cursor)
  (let ([p (views:cursor-point cursor)] [m (views:cursor-mark cursor)]
        [doc (buffers:document (views:buffer view))])
    (if m
        (let ([from (min (%column doc p) (%column doc m))] [to (max (%column doc p) (%column doc m))])
          (let loop ([line (document:line doc (max p m))] [acc '()])
            (if (< line (document:line doc (min p m)))
                acc
                (let ([start (document:offset doc (document:line-start doc line) chars)]
                      [end (document:offset doc (%line-end doc line) chars)])
                  (loop (- line 1)
                        (cons (cons (document:position doc (min (+ start from) end) chars)
                                    (document:position doc (min (+ start to) end) chars))
                              acc))))))
        (region-ranges view cursor))))

(define (%insert-lines buffer position lines)
  (let* ([doc (buffers:document buffer)] [first (document:line doc position)] [column (%column doc position)])
    (let loop ([lines lines] [line first] [end position])
      (if (null? lines)
          end
          (let ([doc (buffers:document buffer)])
            (when (> line (document:line doc (- (document:length doc) 1)))
              (buffers:insert! buffer (- (document:length doc) 1) "\n"))
            (let* ([doc (buffers:document buffer)]
                   [start (document:line-start doc line)]
                   [width (- (document:offset doc (%line-end doc line) chars) (document:offset doc start chars))]
                   [at (if (< width column)
                           (buffers:insert! buffer (%line-end doc line) (make-string (- column width) #\space))
                           (document:position doc (+ (document:offset doc start chars) column) chars))])
              (loop (cdr lines) (+ line 1) (buffers:insert! buffer at (car lines)))))))))

(define (kill extract-region view cursor ranges)
  (let* ([doc (buffers:document (views:buffer view))]
         [lines (map (lambda (r) (buffers:text-between doc (car r) (cdr r))) ranges)])
    (kill-ring:make-kill (list (extract-region view cursor ranges))
      (lambda (buffer position) (%insert-lines buffer position lines)))))

;; A cursor's region is a rectangle while it has a mark, as ranges
;; decides, so its lines go back in as one.
(define (insert-region insert-region! view cursor position lines)
  (if (views:cursor-mark cursor)
      (%insert-lines (views:buffer view) position lines)
      (insert-region! view cursor position lines)))
