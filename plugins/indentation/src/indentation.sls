#!tuna
(import (buffers) (document) (modes) (views) (options) (tables))

(tables:define-table indenters
  "Maps a major mode to its indenter, a procedure of a buffer and the start of a line's text that returns the column for that text, or #f to leave the line as it is.")

(options:define-option use-tabs? #f boolean?
  "Whether indentation is written with tabs as far as they reach, then spaces; read in the buffer's scope.")

(define-condition-type &indenter-error &assertion %make-indenter-error indenter-error?)

(define (blank? v) (or (eqv? v #\space) (eqv? v #\tab)))

(define (blanks-end doc start end)
  (unless (document? doc)
    (assertion-violation 'indentation:blanks-end "not a document" doc))
  (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end (document:length doc)))
    (assertion-violation 'indentation:blanks-end "not a range in the document" start end))
  (let loop ([p start])
    (if (and (fx< p end) (blank? (document:token doc p))) (loop (fx+ p 1)) p)))

(define (blanks-start doc start end)
  (unless (document? doc)
    (assertion-violation 'indentation:blanks-start "not a document" doc))
  (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end (document:length doc)))
    (assertion-violation 'indentation:blanks-start "not a range in the document" start end))
  (let loop ([p end])
    (if (and (fx> p start) (blank? (document:token doc (fx- p 1)))) (loop (fx- p 1)) p)))

(define (%tab-width buffer) (buffers:with-buffer buffer (views:tab-width)))

;; As Emacs's indent-to: from one column to another, tabs as far as they
;; reach when use-tabs? is true, then spaces.
(define (%blanks buffer from to)
  (let ([width (%tab-width buffer)])
    (if (and (buffers:with-buffer buffer (use-tabs?)) (fx> (fxquotient to width) (fxquotient from width)))
        (string-append (make-string (fx- (fxquotient to width) (fxquotient from width)) #\tab)
                       (make-string (fxremainder to width) #\space))
        (make-string (fxmax 0 (fx- to from)) #\space))))

(module %internals
  (check-main-thread check-buffer check-position indenter-of text-start indentation-end line-end? fallback-column
   indent-line! non-empty-line-above)

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
        [(tables:ref indenters (car modes) #f)]
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

  (define (fallback-column buffer line)
    (let ([doc (buffers:document buffer)])
      (let loop ([line (fx- line 1)])
        (if (fx< line 1)
            0
            (let ([e (indentation-end doc (text-start doc line))])
              (if (line-end? doc e)
                  (loop (fx- line 1))
                  (document:column doc e (%tab-width buffer))))))))

  (define (non-empty-line-above doc line)
    (let loop ([line (fx- line 1)])
      (cond
        [(fx< line 1) #f]
        [(line-end? doc (text-start doc line)) (loop (fx- line 1))]
        [else line])))

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
      (let ([text (if (fx= (document:column doc end (%tab-width buffer)) column)
                      end
                      (let ([blanks (%blanks buffer 0 column)])
                        (buffers:replace! buffer start end blanks)
                        (fx+ start (string-length blanks))))])
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
        (let ([column (guard (c [(and (condition? c) (not (cancelled? c)))
                                 (%raise-indenter-error
                                   (format "the indenter of ~s raised: ~a" mode
                                     (call-with-string-output-port (lambda (p) (display-condition c p))))
                                   (list found) c)]
                                [(not (cancelled? c))
                                 (%raise-indenter-error (format "the indenter of ~s raised: ~s" mode c) (list found))])
                        (found buffer start))])
          (unless (or (not column) (and (fixnum? column) (fx>= column 0)))
            (%raise-indenter-error "the indenter returned neither a column nor #f" (list found column)))
          column)
        (fallback-column buffer (document:line (buffers:document buffer) start)))))

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

(define (column buffer position)
  (check-buffer 'indentation:column buffer)
  (document:column (buffers:document buffer) position (%tab-width buffer)))

(define (column-position buffer line column)
  (check-buffer 'indentation:column-position buffer)
  (document:column-position (buffers:document buffer) line column (%tab-width buffer)))

(define (blanks buffer from to)
  (check-buffer 'indentation:blanks buffer)
  (unless (and (fixnum? from) (fixnum? to) (fx<= 0 from))
    (assertion-violation 'indentation:blanks "not columns" from to))
  (%blanks buffer from to))

(define (relative-column buffer position)
  (check-buffer 'indentation:relative-column buffer)
  (check-position 'indentation:relative-column buffer position)
  (let* ([doc (buffers:document buffer)] [width (%tab-width buffer)] [goal (document:column doc position width)]
         [above (non-empty-line-above doc (document:line doc position))])
    (and above
         (let* ([at (document:column-position doc above goal width)]
                [at (if (and (fx> at (text-start doc above)) (fx> (document:column doc at width) goal)) (fx- at 1) at)]
                [word-end (if (blank? (document:token doc at))
                              at
                              (let loop ([p at]) (if (or (line-end? doc p) (blank? (document:token doc p))) p (loop (fx+ p 1)))))]
                [point (blanks-end doc word-end (document:length doc))])
           (and (not (line-end? doc point))
                (document:column doc point width))))))
