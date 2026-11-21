#!tuna
(import (buffers) (document) (modes) (views))

(define-table indenters
  "Maps a major mode to its indenter, a procedure of a buffer and the start of a line's text that returns the column for that text, or #f to leave the line as it is.")

(define-condition-type &indenter-error &assertion %make-indenter-error indenter-error?)

(define (blank? v) (or (eqv? v #\space) (eqv? v #\tab)))

(define (blanks-end doc start end)
  (unless (document? doc)
    (assertion-violation 'indentation:blanks-end "not a document" doc))
  (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end (document:length doc)))
    (assertion-violation 'indentation:blanks-end "not a range in the document" start end))
  (let loop ([p start])
    (if (and (fx< p end) (blank? (document:token doc p))) (loop (fx+ p 1)) p)))

(module %internals
  (check-main-thread check-buffer check-position indenter-of text-start indentation-end line-end? fallback-column
   indent-line!)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define (check-buffer who v)
    (unless (buffers:buffer? v)
      (assertion-violation who "not a buffer" v)))

  (define (check-position who buffer p)
    (unless (and (fixnum? p) (fx<= 0 p (document:length (buffers:document buffer))))
      (assertion-violation who "not a position in the buffer" p)))

  (define (indenter-of mode)
    (let loop ([modes (modes:ancestry mode)])
      (cond
        [(null? modes) #f]
        [(table-ref indenters (car modes) #f)]
        [else (loop (cdr modes))])))

  ;; A line starts before the openings of nodes that begin on it, as a
  ;; file buffer's first line starts before its root node.
  (define (text-start doc line)
    (let ([n (document:length doc)])
      (let loop ([p (document:line-start doc line)])
        (let ([t (and (fx< p n) (document:token doc p))])
          (if (and t (document:node? t) (not (document:atom? t)))
              (loop (fx+ p 1))
              p)))))

  (define (indentation-end doc start) (blanks-end doc start (document:length doc)))

  (define (line-end? doc p)
    (or (fx= p (document:length doc))
        (let ([t (document:token doc p)])
          (or (eqv? t #\newline) (eq? t 'close)))))

  (define (fallback-column doc line)
    (let loop ([line (fx- line 1)])
      (if (fx< line 1)
          0
          (let ([e (indentation-end doc (text-start doc line))])
            (if (line-end? doc e)
                (loop (fx- line 1))
                (document:column doc e))))))

  (define (indent-line! buffer start column place)
    (let* ([doc (buffers:document buffer)]
           [end (indentation-end doc start)]
           [inside (fold-left
                     (lambda (acc view)
                       (fold-left
                         (lambda (acc c)
                           (let ([p (views:cursor-point c)])
                             (if (fx<= start p end) (cons (list view c p) acc) acc)))
                         acc (views:cursors view)))
                     '() (views:showing buffer))])
      ;; As Emacs, a line whose text already starts at the column keeps
      ;; its blanks, tabs included.
      (let ([text (if (fx= (document:column doc end) column)
                      end
                      (begin (buffers:replace! buffer start end (make-string column #\space)) (fx+ start column)))])
        (for-each
          (lambda (entry)
            (let-values ([(view c p) (apply values entry)])
              (when (memq c (views:cursors view))
                (views:set-cursor! c (place p text) (views:cursor-mark c)))))
          inside)))))

(import %internals)

(define (indenter mode)
  (unless (symbol? mode)
    (assertion-violation 'indentation:indenter "not a mode" mode))
  (indenter-of mode))

(define (%raise-indenter-error message irritants . inner)
  (raise (apply condition (%make-indenter-error) (make-who-condition 'indentation:line!)
           (make-message-condition message) (make-irritants-condition irritants) inner)))

(define (%column-of buffer start)
  (let* ([mode (modes:major-mode buffer)] [found (indenter-of mode)])
    (if found
        (let ([column (guard (c [(and (condition? c) (not (quit-condition? c)))
                                 (%raise-indenter-error
                                   (format "the indenter of ~s raised: ~a" mode
                                     (call-with-string-output-port (lambda (p) (display-condition c p))))
                                   (list found) c)]
                                [(not (quit-condition? c))
                                 (%raise-indenter-error (format "the indenter of ~s raised: ~s" mode c) (list found))])
                        (found buffer start))])
          (unless (or (not column) (and (fixnum? column) (fx>= column 0)))
            (%raise-indenter-error "the indenter returned neither a column nor #f" (list found column)))
          column)
        (fallback-column (buffers:document buffer) (document:line (buffers:document buffer) start)))))

(define (%indent! buffer position place)
  (let* ([doc (buffers:document buffer)]
         [start (text-start doc (document:line doc position))]
         [column (%column-of buffer start)])
    (when column
      (indent-line! buffer start column place))))

(define (line! buffer position)
  (check-main-thread 'indentation:line!)
  (check-buffer 'indentation:line! buffer)
  (check-position 'indentation:line! buffer position)
  (%indent! buffer position (lambda (p text) text)))

;; Empty lines stay empty, as Emacs's indent-region leaves them, so
;; indenting a range adds no trailing blanks. Each cursor keeps its place,
;; as Emacs's indent-region keeps point with save-excursion: in the
;; indentation it stays before the blanks a line gains.
(define lines!
  (case-lambda
    [(buffer)
     (check-buffer 'indentation:lines! buffer)
     (lines! buffer 0 (document:length (buffers:document buffer)))]
    [(buffer start end)
     (check-main-thread 'indentation:lines!)
     (check-buffer 'indentation:lines! buffer)
     (check-position 'indentation:lines! buffer start)
     (check-position 'indentation:lines! buffer end)
     (let* ([doc (buffers:document buffer)]
            [first (document:line doc (fxmin start end))]
            [last (document:line doc (fxmax start end))])
       (do ([line first (fx+ line 1)]) ((fx> line last))
         (let ([s (text-start (buffers:document buffer) line)])
           (unless (line-end? (buffers:document buffer) s)
             (%indent! buffer s fxmin)))))]))
