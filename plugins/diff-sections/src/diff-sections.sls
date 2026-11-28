#!tuna
(import (diff) (ui) (buffers) (document) (views) (faces) (web) (haml) (hooks) (options) (tables))

(options:define-option line-numbers? #f boolean?
  "Whether each hunk line is drawn with its old and new line numbers in a gutter, which is drawing, not text.")

(define-enumeration layout-mode (unified split automatic) %layout-modes)

(options:define-option layout (layout-mode unified) (lambda (v) (and (memq v (enum-set->list (enum-set-universe (%layout-modes)))) #t))
  "How a hunk's lines are drawn: unified in one column, split in two, or automatic, split when the view is wide; a buffer may set it locally.")

(define-record-type (%refiner make-refiner refiner?)
  (sealed #t)
  (fields name available? refine owner)
  (protocol
    (lambda (new)
      (lambda (name available? refine)
        (unless (string? name)
          (assertion-violation 'diff-sections:make-refiner "not a string" name))
        (unless (procedure? available?)
          (assertion-violation 'diff-sections:make-refiner "not a procedure" available?))
        (unless (procedure? refine)
          (assertion-violation 'diff-sections:make-refiner "not a procedure" refine))
        (new name available? refine (current-owner))))))

(define (refiner-name refiner)
  (unless (refiner? refiner)
    (assertion-violation 'diff-sections:refiner-name "not a refiner" refiner))
  (%refiner-name refiner))

(options:define-option refiner #f (lambda (v) (or (not v) (refiner? v)))
  "The refiner that draws, or #f for none; a buffer may set it locally.")

(tables:define-table refiners "The refiners, as keys, that a menu offers.")

(options:define-option source #f (lambda (v) (or (not v) (procedure? v)))
  "A procedure of the section holding file sections, #f for the buffer's top, an external diff command and a list of diff:file values, that returns the bytes git writes when it runs that section's diff through the command on those files only; a screen sets it locally.")

(module %internals (decoded padded-word line-face check-file sequence-length)

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
  (let* ([columns? (memq (document:node-attribute node 'layout 'unified) '(split automatic))]
         [cell-number (lambda (side)
                        (if (and columns? (line-numbers?))
                            (haml (:span.diff-sections-cell-number ([aria-hidden "true"])
                                    (let ([n (document:node-attribute node side)]) (if n (number->string n) ""))))
                            '()))]
         [numbers (if (line-numbers?)
                      (haml (:span.diff-sections-numbers ([aria-hidden "true"])
                              (:span (let ([n (document:node-attribute node 'old)]) (if n (number->string n) "")))
                              (:span (let ([n (document:node-attribute node 'new)]) (if n (number->string n) "")))))
                      '())]
         [marker (if (document:node-attribute node 'no-newline)
                     (haml (:div.diff-sections-no-newline ([data-face (symbol->string faces:shadow)])
                             "\\ No newline at end of file"))
                     '())])
    (haml (:div.diff-sections-line ([data-face (line-face (document:node-attribute node 'kind))]
                                    [data-layout (symbol->string (document:node-attribute node 'layout 'unified))]
                                    [data-side (symbol->string (document:node-attribute node 'side 'both))]
                                    [style (string-append "--diff-sections-row: " (number->string (document:node-attribute node 'row 1)))])
            numbers
            (:div.diff-sections-text (cell-number (if (eq? (document:node-attribute node 'side 'both) 'right) 'new 'old))
              (views:draw-children view node) marker)
            (when (and columns? (eq? (document:node-attribute node 'kind) 'context))
              (:div.diff-sections-copy ([aria-hidden "true"])
                (cell-number 'new)
                (document:text (buffers:document (views:buffer view)) (fx+ (document:node-start node) 1) (fx- (document:node-end node) 2))))))))

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

(define (%line-datum hunk index line layout row)
  (let-values ([(old new) (diff:line-numbers hunk index)])
    (let ([prefix (diff:line-prefix line)]
          [text (append (decoded (diff:line-bytes line)) '("\n"))])
      (apply %line `((kind . ,(diff:line-kind line)) (index . ,index) (old . ,old) (new . ,new)
                     (no-newline . ,(diff:line-no-newline? line)) (layout . ,layout) (row . ,(car row)) (side . ,(cdr row)))
             (cond
               [(fx> (bytevector-length prefix) 1)
                (append (map (lambda (b) (%column `((mark . ,(integer->char b))) (string (integer->char b))))
                             (bytevector->u8-list prefix))
                        text)]
               [else (cons (utf8->string prefix) text)])))))

(define (%rows hunk pairs)
  (let* ([lines (diff:hunk-lines hunk)] [n (vector-length lines)] [rows (make-vector n #f)])
    (define (kind i) (diff:line-kind (vector-ref lines i)))
    (define (run-end i k) (if (and (fx< i n) (eq? (kind i) k)) (run-end (fx+ i 1) k) i))
    (define (number i side) (let-values ([(old new) (diff:line-numbers hunk i)]) (if (eq? side 'left) old new)))
    (define (partner-of i added-start added-end)
      (let ([p (assv (number i 'left) pairs)])
        (and p (cdr p)
             (let find ([k added-start]) (cond [(fx= k added-end) #f] [(eqv? (number k 'right) (cdr p)) k] [else (find (fx+ k 1))])))))
    (define (place-run! removed-start removed-end added-start added-end row)
      (let loop ([i removed-start] [next added-start] [row row])
        (if (fx= i removed-end)
            (let rest ([k next] [row row])
              (if (fx= k added-end) row (begin (vector-set! rows k (cons row 'right)) (rest (fx+ k 1) (fx+ row 1)))))
            (let ([partner (let ([p (if pairs
                                        (partner-of i added-start added-end)
                                        (let ([k (fx+ added-start (fx- i removed-start))]) (and (fx< k added-end) k)))])
                             (and p (fx>= p next) p))])
              (if partner
                  (let before ([k next] [row row])
                    (if (fx< k partner)
                        (begin (vector-set! rows k (cons row 'right)) (before (fx+ k 1) (fx+ row 1)))
                        (begin
                          (vector-set! rows i (cons row 'left))
                          (vector-set! rows partner (cons row 'right))
                          (loop (fx+ i 1) (fx+ partner 1) (fx+ row 1)))))
                  (begin (vector-set! rows i (cons row 'left)) (loop (fx+ i 1) next (fx+ row 1))))))))
    (let loop ([i 0] [row 1])
      (cond
        [(fx= i n) rows]
        [(eq? (kind i) 'context) (vector-set! rows i (cons row 'both)) (loop (fx+ i 1) (fx+ row 1))]
        [else
         (let* ([removed-end (run-end i 'removed)] [added-end (run-end removed-end 'added)])
           (loop added-end (place-run! i removed-end removed-end added-end row)))]))))

(define (hunk-rows hunk)
  (unless (diff:hunk? hunk)
    (assertion-violation 'diff-sections:hunk-rows "not a hunk" hunk))
  (%rows hunk #f))

(define (%hunk-datum file hunk layout pairs)
  (let* ([lines (diff:hunk-lines hunk)]
         [combined? (diff:file-combined? file)]
         [rows (if combined?
                   (let ([v (make-vector (vector-length lines))])
                     (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length v)) v) (vector-set! v i (cons (fx+ i 1) 'both))))
                   (%rows hunk pairs))]
         [layout (if combined? 'unified layout)])
    (apply ui:section `((type . hunk) (value . ,(utf8->string (diff:hunk-heading hunk))) (hunk . ,hunk))
           (decoded (diff:hunk-heading hunk))
           (let loop ([i (fx- (vector-length lines) 1)] [acc '()])
             (if (fx< i 0) acc (loop (fx- i 1) (cons (%line-datum hunk i (vector-ref lines i) layout (vector-ref rows i)) acc)))))))

(define (hunk-section file hunk)
  (check-file 'diff-sections:hunk-section file)
  (unless (diff:hunk? hunk)
    (assertion-violation 'diff-sections:hunk-section "not a hunk" hunk))
  (%hunk-datum file hunk (layout) (%pairs-of file)))

(define file-section
  (case-lambda
    [(file) (file-section file '() ui:section)]
    [(file attributes) (file-section file attributes ui:section)]
    [(file attributes section)
     (check-file 'diff-sections:file-section file)
     (unless (and (list? attributes) (for-all pair? attributes))
       (assertion-violation 'diff-sections:file-section "not an association list of attributes" attributes))
     (unless (procedure? section)
       (assertion-violation 'diff-sections:file-section "not a procedure" section))
     (apply section (append `((type . file) (value . ,(diff:file-path file)) (file . ,file)) attributes)
            (%file-heading file)
            (%file-body file))]))

(define (%file-body file)
  (if (diff:file-binary? file)
      '("Binary files differ")
      (let ([layout (layout)] [pairs (%pairs-of file)])
        (map (lambda (h) (%hunk-datum file h layout pairs)) (diff:file-hunks file)))))

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
     (unless (or (eq? (ui:section-type section) 'file) (buffers:buffer? buffer))
       (assertion-violation 'diff-sections:file "a hunk section's file needs its buffer" buffer))
     (let ([f (if (eq? (ui:section-type section) 'file) section (file-section-of section buffer))])
       (and f (document:node-attribute f 'file #f)))]))

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

(define (%count-text n singular plural) (string-append (number->string n) " " (if (= n 1) singular plural)))

(define (%counts file)
  (call-with-values (lambda () (diff:file-line-counts file)) cons))

(define (%draw-stat-row node view)
  (let ([added (document:node-attribute node 'added 0)] [removed (document:node-attribute node 'removed 0)]
        [most (document:node-attribute node 'most 0)])
    (define (bar n) (if (fx= most 0) 0 (fxmax (if (fx> n 0) 1 0) (fxdiv (fx* n 20) (fxmax most 20)))))
    (haml (:span.diff-sections-stat-row
            (views:draw-children view node)
            (:span.diff-sections-stat-bar ([aria-hidden "true"])
              (:span ([data-face (symbol->string faces:diff.plus)]) (make-string (bar added) #\+))
              (:span ([data-face (symbol->string faces:diff.minus)]) (make-string (bar removed) #\-)))))))

(buffers:define-kind %stat-row (inline) (draw %draw-stat-row))

;; The bar is drawn, not text, so a copied row is git's --stat row
;; without it.
(define diffstat-section
  (case-lambda
    [(files) (diffstat-section files '() ui:section)]
    [(files attributes) (diffstat-section files attributes ui:section)]
    [(files attributes section)
     (unless (and (list? files) (for-all diff:file? files))
       (assertion-violation 'diff-sections:diffstat-section "not a list of file diffs" files))
     (unless (and (list? attributes) (for-all pair? attributes))
       (assertion-violation 'diff-sections:diffstat-section "not an association list of attributes" attributes))
     (unless (procedure? section)
       (assertion-violation 'diff-sections:diffstat-section "not a procedure" section))
     (let* ([counts (map %counts files)]
            [added (fold-left + 0 (map car counts))] [removed (fold-left + 0 (map cdr counts))]
            [names (map (lambda (f) (diff:file-path f)) files)]
            [width (fold-left (lambda (w n) (fxmax w (string-length n))) 0 names)]
            [numbers (map (lambda (f c) (if (diff:file-binary? f) "Bin" (number->string (+ (car c) (cdr c))))) files counts)]
            [number-width (fold-left (lambda (w n) (fxmax w (string-length n))) 0 numbers)]
            [most (fold-left (lambda (m c) (max m (+ (car c) (cdr c)))) 0 counts)])
       (apply ui:section '((type . diffstat) (value . #f))
              (apply string-append
                     (%count-text (length files) "file changed" "files changed")
                     (append (if (> added 0) (list ", " (%count-text added "insertion(+)" "insertions(+)")) '())
                             (if (> removed 0) (list ", " (%count-text removed "deletion(-)" "deletions(-)")) '())))
              (map (lambda (f name number c)
                     (section (append `((type . file) (value . ,name) (file . ,f)) attributes)
                              (list (%stat-row `((added . ,(car c)) (removed . ,(cdr c)) (most . ,most))
                                               (string-append name (make-string (fx- width (string-length name)) #\space) " | "
                                                              (make-string (fx- number-width (string-length number)) #\space) number)))))
                   files names numbers counts)))]))

(define-record-type (%refinement make-refinement refinement?)
  (sealed #t)
  (fields path old-blob new-blob novel pairs unchanged?)
  (protocol
    (lambda (new)
      (lambda (path old-blob new-blob novel pairs unchanged?)
        (unless (bytevector? path)
          (assertion-violation 'diff-sections:make-refinement "not a bytevector" path))
        (unless (and (or (not old-blob) (string? old-blob)) (or (not new-blob) (string? new-blob)))
          (assertion-violation 'diff-sections:make-refinement "not a blob name" old-blob new-blob))
        (unless (and (list? novel)
                     (for-all (lambda (n) (and (list? n) (fx= (length n) 4) (memq (car n) '(old new))
                                               (for-all fixnum? (cdr n))))
                              novel))
          (assertion-violation 'diff-sections:make-refinement "not a list of (side line start end)" novel))
        (unless (and (list? pairs) (for-all (lambda (p) (and (pair? p) (or (not (car p)) (fixnum? (car p))) (or (not (cdr p)) (fixnum? (cdr p))))) pairs))
          (assertion-violation 'diff-sections:make-refinement "not a list of line pairs" pairs))
        (new path old-blob new-blob novel pairs (and unchanged? #t))))))

(define-record-type (%request %make-request request?)
  (sealed #t)
  (fields buffer refiner files run))

(define (request-files request)
  (unless (request? request)
    (assertion-violation 'diff-sections:request-files "not a request" request))
  (%request-files request))

(define (request-run request)
  (unless (request? request)
    (assertion-violation 'diff-sections:request-run "not a request" request))
  (%request-run request))

;; Another refiner's answer for a file is not this one's.
(define (%key-of refiner file) (list refiner (diff:file-path-bytes file) (diff:file-old-blob file) (diff:file-new-blob file)))

(define %refinements (make-hashtable equal-hash equal?))

(define %pending (make-hashtable equal-hash equal?))

(define %held (make-weak-eq-hashtable))

;; A refiner whose plugin has unloaded cannot run, so a buffer that still
;; names it, as a local value set by another plugin can, has no refiner.
(define (%refiner-in-effect)
  (let ([r (refiner)])
    (and r (owner-live? (%refiner-owner r)) r)))

(define (refiner-of buffer)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'diff-sections:refiner-of "not a buffer" buffer))
  (buffers:with-buffer buffer (%refiner-in-effect)))

(define (%refinement-of refiner file)
  (let ([r (and refiner (hashtable-ref %refinements (%key-of refiner file) #f))])
    (and (refinement? r) r)))

(define (%pairs-of file)
  (and (not (diff:file-combined? file))
       (let ([r (%refinement-of (%refiner-in-effect) file)]) (and r (%refinement-pairs r)))))

(define (file-section-of section buffer)
  (unless (and (document:node? section) (buffers:buffer? buffer))
    (assertion-violation 'diff-sections:file-section-of "not a section and its buffer" section buffer))
  (case (ui:section-type section)
    [(file) section]
    [(hunk) (ui:section-parent section buffer)]
    [else #f]))

;; The diffstat's rows are file sections of their files, which hold no
;; hunks to refine or rebuild.
(define (%file-sections b)
  (let walk ([sections (ui:top-sections b)])
    (apply append
      (map (lambda (s)
             (cond
               [(eq? (ui:section-type s) 'diffstat) '()]
               [(and (eq? (ui:section-type s) 'file) (document:node-attribute s 'file #f)) (list s)]
               [else (walk (ui:section-children s))]))
           sections))))

(define (%shown? b section)
  (exists (lambda (v) (not (ui:section-hidden? v section))) (views:showing b)))

(define (%hold! b)
  (let ([refiner (refiner-of b)])
    (eq-hashtable-set! %held b
      (if refiner (map (lambda (s) (%key-of refiner (document:node-attribute s 'file))) (%file-sections b)) '()))))

;; A request whose refiner's plugin has unloaded will never be answered.
(define (%drop-unheld!)
  (let ([held (make-hashtable equal-hash equal?)])
    (vector-for-each (lambda (keys) (for-each (lambda (k) (hashtable-set! held k #t)) keys)) (hashtable-values %held))
    (vector-for-each (lambda (k) (unless (hashtable-contains? held k) (hashtable-delete! %refinements k)))
                     (hashtable-keys %refinements))
    (vector-for-each (lambda (k) (unless (owner-live? (%refiner-owner (car k))) (hashtable-delete! %pending k)))
                     (hashtable-keys %pending))))

(define (%group-by-container b sections)
  (let loop ([sections sections] [groups '()])
    (if (null? sections)
        (reverse (map (lambda (g) (cons (car g) (reverse (cdr g)))) groups))
        (let* ([s (car sections)] [parent (ui:section-parent s b)]
               [g (find (lambda (g) (if (car g) (and parent (fx= (document:node-start (car g)) (document:node-start parent))) (not parent)))
                        groups)])
          (if g
              (begin (set-cdr! g (cons s (cdr g))) (loop (cdr sections) groups))
              (loop (cdr sections) (cons (list parent s) groups)))))))

(define (refine! buffer)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'diff-sections:refine! "not a buffer" buffer))
  (when (buffers:live? buffer)
    (let-values ([(refiner source) (buffers:with-buffer buffer (values (%refiner-in-effect) (source)))])
      (when source
        (%hold! buffer)
        (%drop-unheld!))
      (when (and refiner source ((%refiner-available? refiner)))
        (let ([wanted (filter (lambda (s)
                                (let* ([f (document:node-attribute s 'file)] [key (%key-of refiner f)])
                                  (and (not (diff:file-binary? f)) (not (diff:file-combined? f))
                                       (not (hashtable-contains? %refinements key))
                                       (not (hashtable-contains? %pending key))
                                       (%shown? buffer s))))
                              (%file-sections buffer))])
          (for-each
            (lambda (group)
              (let* ([files (map (lambda (s) (document:node-attribute s 'file)) (cdr group))]
                     [request (%make-request buffer refiner files (lambda (external) (source (car group) external files)))])
                (for-each (lambda (f) (hashtable-set! %pending (%key-of refiner f) request)) files)
                ((%refiner-refine refiner) request)))
            (%group-by-container buffer wanted))))
      (when source
        (%paint! buffer)))))

;; Every buffer showing a delivered file gets its hunks and spans, not
;; only the one that asked: another may have found the file pending.
(define (%redraw! keys)
  (for-each
    (lambda (b)
      (when (and (buffers:live? b) (exists (lambda (k) (member k keys)) (eq-hashtable-ref %held b '())))
        (let ([refiner (refiner-of b)])
          (for-each
            (lambda (s)
              (let ([f (document:node-attribute s 'file)])
                (when (and refiner (member (%key-of refiner f) keys))
                  (buffers:with-buffer b
                    (buffers:with-silent-edits b
                      (buffers:reconcile! b s (cddr (file-section f))))))))
            (%file-sections b))
          (%hold! b)
          (%paint! b))))
    (vector->list (hashtable-keys %held))))

;; A file the refiner answered nothing for is held as none, so it is not
;; asked for again. Only the keys still pending on this request are kept:
;; a forget! since the request began means its answers are no longer the
;; refiner's.
(define (deliver! request refinements)
  (unless (request? request)
    (assertion-violation 'diff-sections:deliver! "not a request" request))
  (unless (and (list? refinements) (for-all refinement? refinements))
    (assertion-violation 'diff-sections:deliver! "not a list of refinements" refinements))
  (let* ([refiner (%request-refiner request)]
         [keys (filter (lambda (key) (eq? request (hashtable-ref %pending key #f)))
                       (map (lambda (f) (%key-of refiner f)) (%request-files request)))])
    (for-each
      (lambda (key)
        (hashtable-delete! %pending key)
        (hashtable-set! %refinements key
                        (or (find (lambda (r) (equal? (cdr key) (list (%refinement-path r) (%refinement-old-blob r) (%refinement-new-blob r))))
                                  refinements)
                            'none)))
      keys)
    (%redraw! keys)
    (%drop-unheld!)))

(define (forget! refiner)
  (unless (refiner? refiner)
    (assertion-violation 'diff-sections:forget! "not a refiner" refiner))
  (let ([forgotten (filter (lambda (k) (eq? (car k) refiner)) (vector->list (hashtable-keys %refinements)))])
    (for-each (lambda (k) (hashtable-delete! %refinements k)) forgotten)
    (vector-for-each (lambda (k) (when (eq? (car k) refiner) (hashtable-delete! %pending k))) (hashtable-keys %pending))
    (%redraw! forgotten)))

(buffers:define-layer %refinement-layer)

;; A column of difft counts bytes; a position counts characters, and a
;; byte that is not UTF-8 is one raw-byte atom.
(define (%position-of-byte bytes column)
  (let loop ([i 0] [p 0])
    (if (or (fx>= i column) (fx>= i (bytevector-length bytes)))
        p
        (let ([k (sequence-length bytes i)]) (loop (fx+ i (or k 1)) (fx+ p 1))))))

(define (%line-spans doc hunk-section refinement)
  (let ([hunk (document:node-attribute hunk-section 'hunk)])
    (let ([spans '()])
      (document:for-each-child hunk-section (fx+ (document:node-start hunk-section) 1) (fx- (document:node-end hunk-section) 1)
        (lambda (child at)
          (when (and (document:node? child) (eq? (document:node-kind child) %line-kind))
            (let ([kind (document:node-attribute child 'kind)])
              (when (memq kind '(added removed))
                (let* ([line (vector-ref (diff:hunk-lines hunk) (document:node-attribute child 'index))]
                       [bytes (diff:line-bytes line)]
                       [text-start (fx+ (document:node-start child) 2)]
                       [text-end (fx- (document:node-end child) 2)]
                       [side (if (eq? kind 'added) 'new 'old)]
                       [number (document:node-attribute child (if (eq? kind 'added) 'new 'old))]
                       [novel (filter (lambda (n) (and (eq? (car n) side) (eqv? (cadr n) number))) (%refinement-novel refinement))]
                       [blank? (for-all (lambda (b) (memv b '(32 9 13))) (bytevector->u8-list bytes))])
                  (cond
                    [(and (pair? novel) (not (%refinement-unchanged? refinement)))
                     (for-each
                       (lambda (n)
                         (let ([start (fxmin text-end (fx+ text-start (%position-of-byte bytes (caddr n))))]
                               [end (fxmin text-end (fx+ text-start (%position-of-byte bytes (cadddr n))))])
                           (when (fx< start end)
                             (set! spans (cons (list start end (list (cons 'face (if (eq? kind 'added) "diff-sections.novel-added" "diff-sections.novel-removed"))))
                                               spans)))))
                       novel)]
                    [(and (not blank?) (fx< text-start text-end))
                     (set! spans (cons (list text-start text-end '((face . "diff-sections.reformatted"))) spans))])))))))
      spans)))

(define (%paint! b)
  (let* ([doc (buffers:document b)] [n (document:length doc)] [layer (buffers:layer b %refinement-layer)]
         [on? (refiner-of b)])
    (buffers:set-spans! layer 0 n
      (if on?
          (list-sort (lambda (x y) (fx< (car x) (car y)))
            (apply append
              (map (lambda (s)
                     (let ([r (%refinement-of on? (document:node-attribute s 'file))])
                       (if r
                           (apply append (map (lambda (h) (%line-spans doc h r))
                                              (filter (lambda (h) (eq? (ui:section-type h) 'hunk)) (ui:section-children s))))
                           '())))
                   (%file-sections b))))
          '()))))

(define (%refine-shown view section) (refine! (views:buffer view)))

(hooks:add! ui:section-shown %refine-shown)
(tables:set! web:stylesheets 'diff-sections "diff-sections/diff-sections.css")
