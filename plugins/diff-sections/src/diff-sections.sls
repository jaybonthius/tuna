#!tuna
(import (diff) (ui) (buffers) (document) (views) (faces) (web) (haml) (options) (tables))

(options:define-option line-numbers? #f boolean?
  "Whether each hunk line is drawn with its old and new line numbers in a gutter, which is drawing, not text.")

(module %internals (decoded padded-word line-face check-file)

  (define (sequence-length bytes i)
    (let ([n (bytevector-length bytes)])
      (define (continuation? k lo hi)
        (and (fx< (fx+ i k) n) (fx<= lo (bytevector-u8-ref bytes (fx+ i k)) hi)))
      (let ([b (bytevector-u8-ref bytes i)])
        (cond
          [(fx< b #x80) 1]
          [(fx<= #xC2 b #xDF) (and (continuation? 1 #x80 #xBF) 2)]
          [(fx<= #xE0 b #xEF)
           (and (continuation? 1 (if (fx= b #xE0) #xA0 #x80) (if (fx= b #xED) #x9F #xBF))
                (continuation? 2 #x80 #xBF) 3)]
          [(fx<= #xF0 b #xF4)
           (and (continuation? 1 (if (fx= b #xF0) #x90 #x80) (if (fx= b #xF4) #x8F #xBF))
                (continuation? 2 #x80 #xBF) (continuation? 3 #x80 #xBF) 4)]
          [else #f]))))

  ;; A byte that is not UTF-8 becomes a raw-byte atom, not U+FFFD, so
  ;; the drawn line keeps its bytes.
  (define (decoded bytes)
    (let ([n (bytevector-length bytes)])
      (define (run start end)
        (let ([part (make-bytevector (fx- end start))])
          (bytevector-copy! bytes start part 0 (fx- end start))
          (utf8->string part)))
      (let loop ([i 0] [start 0] [acc '()])
        (cond
          [(fx= i n) (reverse (if (fx< start i) (cons (run start i) acc) acc))]
          [(sequence-length bytes i) => (lambda (k) (loop (fx+ i k) start acc))]
          [else
           (loop (fx+ i 1) (fx+ i 1)
                 (cons (vector 'document:raw-byte `((byte . ,(bytevector-u8-ref bytes i))))
                       (if (fx< start i) (cons (run start i) acc) acc)))]))))

  (define (padded-word word)
    (string-append word (make-string (fxmax 1 (fx- 11 (string-length word))) #\space)))

  (define (line-face kind)
    (case kind
      [(added) (symbol->string faces:diff.plus)]
      [(removed) (symbol->string faces:diff.minus)]
      [else "diff-sections.context"]))

  (define (check-file who file)
    (unless (diff:file? file)
      (assertion-violation who "not a file diff" file))))

(import %internals)

(define (%column-face mark)
  (case mark
    [(#\+) (symbol->string faces:diff.plus)]
    [(#\-) (symbol->string faces:diff.minus)]
    [else #f]))

(define (%draw-column node view)
  (haml (:span ([data-face (%column-face (document:node-attribute node 'mark))]) (views:draw-children view node))))

;; The gutter and the no-newline marker are drawing, not text, so a copy
;; of the lines is a patch.
(define (%draw-line node view)
  (let ([numbers (if (line-numbers?)
                     (haml (:span.diff-sections-numbers ([aria-hidden "true"])
                             (:span (let ([n (document:node-attribute node 'old)]) (if n (number->string n) "")))
                             (:span (let ([n (document:node-attribute node 'new)]) (if n (number->string n) "")))))
                     '())]
        [marker (if (document:node-attribute node 'no-newline)
                    (haml (:div.diff-sections-no-newline ([data-face (symbol->string faces:shadow)])
                            "\\ No newline at end of file"))
                    '())])
    (haml (:div.diff-sections-line ([data-face (line-face (document:node-attribute node 'kind))])
            numbers
            (:div.diff-sections-text (views:draw-children view node) marker)))))

(buffers:define-kind %line (draw %draw-line))

(buffers:define-kind %column (inline) (draw %draw-column))

(define %line-kind (buffers:kind-name (buffers:constructor-kind %line)))

(define (status-word file)
  (check-file 'diff-sections:status-word file)
  (case (diff:file-status file)
    [(added) "new file"]
    [(deleted) "deleted"]
    [(renamed) "renamed"]
    [(copied) "copied"]
    [(type-changed) "typechange"]
    [(unmerged) "unmerged"]
    [else "modified"]))

(define (%path-content bytes) (decoded bytes))

(define (%file-heading file)
  (let ([old (diff:file-old-path-bytes file)] [new (diff:file-new-path file)])
    (cons (padded-word (status-word file))
          (if (and (memq (diff:file-status file) '(renamed copied)) old new)
              (append (%path-content old) '(" -> ") (%path-content (diff:file-path-bytes file)))
              (%path-content (diff:file-path-bytes file))))))

(define (%line-datum hunk index line)
  (let-values ([(old new) (diff:line-numbers hunk index)])
    (let ([prefix (diff:line-prefix line)]
          [text (append (decoded (diff:line-bytes line)) '("\n"))])
      (apply %line `((kind . ,(diff:line-kind line)) (index . ,index) (old . ,old) (new . ,new)
                     (no-newline . ,(diff:line-no-newline? line)))
             (cond
               [(fx> (bytevector-length prefix) 1)
                (append (map (lambda (b) (%column `((mark . ,(integer->char b))) (string (integer->char b))))
                             (bytevector->u8-list prefix))
                        text)]
               [else (cons (utf8->string prefix) text)])))))

(define (hunk-section file hunk)
  (check-file 'diff-sections:hunk-section file)
  (unless (diff:hunk? hunk)
    (assertion-violation 'diff-sections:hunk-section "not a hunk" hunk))
  (let ([lines (diff:hunk-lines hunk)])
    (apply ui:section `((type . hunk) (value . ,(utf8->string (diff:hunk-heading hunk))) (hunk . ,hunk))
           (decoded (diff:hunk-heading hunk))
           (let loop ([i (fx- (vector-length lines) 1)] [acc '()])
             (if (fx< i 0) acc (loop (fx- i 1) (cons (%line-datum hunk i (vector-ref lines i)) acc)))))))

(define file-section
  (case-lambda
    [(file) (file-section file '())]
    [(file attributes)
     (check-file 'diff-sections:file-section file)
     (unless (and (list? attributes) (for-all pair? attributes))
       (assertion-violation 'diff-sections:file-section "not an association list of attributes" attributes))
     (apply ui:section (append `((type . file) (value . ,(diff:file-path file)) (file . ,file)) attributes)
            (%file-heading file)
            (if (diff:file-binary? file)
                '("Binary files differ")
                (map (lambda (h) (hunk-section file h)) (diff:file-hunks file))))]))

(define (%check-section who section type)
  (unless (and (document:node? section) (eq? (ui:section-type section) type))
    (assertion-violation who (format "not a ~a section" type) section)))

;; A hunk section keeps its hunk alone, so a file of many hunks is not
;; copied into each; its file is its parent's.
(define file
  (case-lambda
    [(section) (file section #f)]
    [(section buffer)
     (unless (and (document:node? section) (memq (ui:section-type section) '(file hunk)))
       (assertion-violation 'diff-sections:file "not a file or hunk section" section))
     (if (eq? (ui:section-type section) 'file)
         (document:node-attribute section 'file)
         (begin
           (unless (buffers:buffer? buffer)
             (assertion-violation 'diff-sections:file "a hunk section's file needs its buffer" buffer))
           (let ([parent (ui:section-parent section buffer)])
             (and parent (eq? (ui:section-type parent) 'file) (document:node-attribute parent 'file)))))]))

(define (hunk section)
  (%check-section 'diff-sections:hunk section 'hunk)
  (document:node-attribute section 'hunk))

(define (%line-node doc p)
  (let loop ([n (and (fx< p (document:length doc)) (document:enclosing doc p))])
    (cond
      [(not n) #f]
      [(eq? (document:node-kind n) %line-kind) n]
      [else (loop (document:enclosing doc (document:node-start n)))])))

(define (%check-view who view)
  (unless (and (views:view? view) (views:buffer view))
    (assertion-violation who "not a view showing a buffer" view)))

(define line-at
  (case-lambda
    [(view) (%check-view 'diff-sections:line-at view) (line-at view (views:point view))]
    [(view position)
     (%check-view 'diff-sections:line-at view)
     (let* ([doc (buffers:document (views:buffer view))] [line (%line-node doc position)])
       (if line
           (values (ui:section-at view position) (document:node-attribute line 'index))
           (values #f #f)))]))

(define (selected-lines view)
  (%check-view 'diff-sections:selected-lines view)
  (let ([ranges (views:region-bounds view)] [doc (buffers:document (views:buffer view))])
    (if (null? ranges)
        (values #f #f #f)
        (let* ([start (caar ranges)] [end (cdar ranges)] [end-line (%line-node doc end)])
          (let-values ([(hunk first) (line-at view start)] [(end-hunk last) (line-at view end)])
            (let ([last (and last (if (fx= end (fx+ (document:node-start end-line) 1)) (fx- last 1) last))])
              (if (and hunk end-hunk first last (fx<= first last)
                       (fx= (document:node-start hunk) (document:node-start end-hunk)))
                  (values hunk first last)
                  (values #f #f #f))))))))

(tables:set! web:stylesheets 'diff-sections "diff-sections/diff-sections.css")
