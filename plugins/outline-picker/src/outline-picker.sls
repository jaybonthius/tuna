#!tuna
(import (outline) (completion) (jump-history) (buffers) (views) (layout) (files) (projects) (modes) (commands) (keys)
        (syntax) (saved) (tables))

(saved:define-saved history '() (lambda (v) (and (list? v) (for-all string? v))))

(completion:define-category entry-category "Entries of buffers' outlines, valued by a pair of the outline and the entry.")

(tables:define-table narrow-characters
  "Maps a kind of outline entry to the character that narrows a read of entries to that kind.")

(define (%string-prefix? prefix s)
  (let ([n (string-length prefix)])
    (and (fx<= n (string-length s)) (string=? prefix (substring s 0 n)))))

(define (%string-suffix? suffix s)
  (let ([n (string-length suffix)] [m (string-length s)])
    (and (fx<= n m) (string=? suffix (substring s (fx- m n) m)))))

(define (%string-holds? s piece)
  (let ([n (string-length piece)] [m (string-length s)])
    (let loop ([i 0])
      (and (fx<= (fx+ i n) m)
           (or (string=? piece (substring s i (fx+ i n))) (loop (fx+ i 1)))))))

(define (find-default name candidates)
  (unless (string? name) (assertion-violation 'outline-picker:find-default "not a string" name))
  (unless (and (list? candidates) (for-all (lambda (c) (and (pair? c) (string? (car c)) (string? (cdr c)))) candidates))
    (assertion-violation 'outline-picker:find-default "not a list of pairs of a candidate's text and its entry's name"
                         candidates))
  (let ([wanted (string-downcase name)])
    (define (first-where fits?)
      (let ([found (find (lambda (c) (fits? (string-downcase (cdr c)))) candidates)])
        (and found (car found))))
    (or (first-where (lambda (n) (string=? n wanted)))
        (first-where (lambda (n) (%string-prefix? wanted n)))
        (first-where (lambda (n) (%string-suffix? wanted n)))
        (first-where (lambda (n) (%string-holds? n wanted))))))

(define-record-type %candidate
  (sealed #t)
  (fields text name-start name value))

(define (%candidates o)
  (let ([paths (outline:paths o)] [found '()])
    (outline:walk o
      (lambda (e ancestors)
        (let ([parents (fold-left (lambda (n a) (fx+ n (string-length (outline:entry-name a)) 1)) 0 ancestors)])
          (set! found (cons (make-%candidate (eq-hashtable-ref paths e #f) parents (outline:entry-name e) (cons o e))
                            found)))))
    (reverse found)))

(define (%kind c) (outline:entry-kind (cdr (%candidate-value c))))

(define (%known-kind kind) (and (tables:ref outline:kinds kind #f) kind))

(define (%kind-title kind)
  (let ([k (tables:ref outline:kinds kind #f)]) (if k (outline:kind-title k) "Other")))

(define (%kind-face kind)
  (let ([k (tables:ref outline:kinds kind #f)]) (and k (outline:kind-face k))))

(define (%preview view)
  (let ([buffer (views:buffer view)] [point (views:point view)] [ended? #f])
    (define (restore!)
      (completion:end-preview-place)
      (views:end-preview! view)
      (when (and (eq? (views:buffer view) buffer) (buffers:live? buffer))
        (views:set-point! view point)))
    (values
      (lambda (choice)
        (cond
          [ended? (void)]
          [(not choice) (restore!)]
          [else
           (let* ([o (car choice)] [b (outline:buffer o)] [at (outline:map o (outline:entry-point (cdr choice)))])
             (when (and at (buffers:live? b))
               (unless (eq? b (views:buffer view)) (views:preview-buffer! view b))
               (completion:preview-place view b at '())
               (jump-history:after-jump view)))]))
      (lambda (choice)
        (unless ended?
          (set! ended? #t)
          (restore!))))))

(define-record-type %group
  (sealed #t)
  (fields title kind candidates))

(define (%source title kind candidates show end)
  (let ([face (%kind-face kind)] [by-value (make-eq-hashtable)])
    (for-each (lambda (c) (eq-hashtable-set! by-value (%candidate-value c) c)) candidates)
    (completion:source
      (candidates (list->vector (map (lambda (c) (cons (%candidate-text c) (%candidate-value c))) candidates)))
      (title title)
      (in-order)
      (narrow (tables:ref narrow-characters kind #\o))
      (category entry-category)
      (faces (lambda (text value)
               (let ([c (eq-hashtable-ref by-value value #f)])
                 (if (and face c)
                     (let ([start (%candidate-name-start c)])
                       (list (list start (fx+ start (string-length (%candidate-name c))) (list (cons 'face face)))))
                     '()))))
      (preview show end))))

(define (%default view candidates)
  (let ([b (views:buffer view)])
    (let-values ([(start end) (syntax:symbol-bounds b (views:point view))])
      (and start (fx< start end)
           (find-default (buffers:text-between (buffers:document b) start end)
                         (map (lambda (c) (cons (%candidate-text c) (%candidate-name c))) candidates))))))

(define (%read question groups candidates view)
  (let-values ([(show end) (%preview view)])
    (completion:read question
      (map (lambda (g) (%source (%group-title g) (%group-kind g) (%group-candidates g) show end)) groups)
      history (%default view candidates))))

(define (%check-entries who o)
  (unless o (error who "This buffer has no outline"))
  (when (null? (outline:roots o)) (error who "The outline is empty")))

(define (%kinds-of candidates)
  (let ([table (make-eq-hashtable)] [order '()])
    (for-each (lambda (c)
                (let ([kind (%known-kind (%kind c))])
                  (unless (eq-hashtable-contains? table kind) (set! order (cons kind order)))
                  (eq-hashtable-update! table kind (lambda (cs) (cons c cs)) '())))
              candidates)
    (values (reverse order) (lambda (kind) (reverse (eq-hashtable-ref table kind '()))))))

(define (%by-kind candidates)
  (let-values ([(kinds of-kind) (%kinds-of candidates)])
    (map (lambda (kind) (make-%group (%kind-title kind) kind (of-kind kind))) kinds)))

(define (%place choice who)
  (let ([at (outline:map (car choice) (outline:entry-point (cdr choice)))])
    (unless at (error who "The buffer changed too much since its outline was made; ask again"))
    at))

(commands:define-command (entry)
  "Reads an entry of the current buffer's outline and moves point to its name, recording the place point left in jump-history."
  (let* ([view (layout:selected-view)] [b (views:buffer view)] [left (views:point view)] [o (outline:get b)])
    (%check-entries 'outline-picker:entry o)
    (let ([candidates (%candidates o)])
      (let* ([choice (%read "Go to item: " (%by-kind candidates) candidates view)]
             [at (%place choice 'outline-picker:entry)])
        (views:set-point! view at)
        (jump-history:push! b left view)
        (jump-history:after-jump view)))))

(define (%project-buffers current all?)
  (let* ([mode (modes:major-mode current)]
         [root (and (not all?) (let ([project (projects:find (files:directory current))]) (and project (projects:root project))))]
         [taken? (lambda (b)
                   (and (not (eq? b current)) (eq? (modes:major-mode b) mode) (not (buffers:internal-name? (buffers:name b)))
                        (or all? (and root (let ([path (files:path b)]) (and path (%string-prefix? root path)))))))])
    (values (list-sort (lambda (a b) (string<? (buffers:name a) (buffers:name b)))
                       (cons current (filter taken? (buffers:all))))
            root)))

(define (%root-name root)
  (let loop ([i (fx- (string-length root) 2)])
    (if (or (fx< i 0) (char=? (string-ref root i) #\/))
        (substring root (fx+ i 1) (fx- (string-length root) 1))
        (loop (fx- i 1)))))

(define (%buffers-word taken) (if (null? (cdr taken)) "buffer" "buffers"))

(define (%kind-order)
  (append (map car (tables:entries outline:kinds)) (list #f)))

(commands:define-command (project-entry)
  "Reads an entry of the outlines of the live buffers of the current buffer's major mode in its project, or with C-u in any, and goes to its name, recording the place point left in jump-history."
  (let* ([view (layout:selected-view)] [current (views:buffer view)])
    (let-values ([(taken root) (%project-buffers current (and (commands:prefix-argument) #t))])
      (let* ([outlines (filter (lambda (o) (and o (pair? (outline:roots o)))) (map outline:get taken))]
             [each (map %candidates outlines)]
             [candidates (apply append each)])
        (when (null? candidates) (%check-entries 'outline-picker:project-entry (outline:get current)))
          (let* ([of-kinds (map (lambda (cs) (let-values ([(kinds of-kind) (%kinds-of cs)]) of-kind)) each)]
               [groups (apply append
                         (map (lambda (kind)
                                (filter values
                                  (map (lambda (o of-kind)
                                         (let ([mine (of-kind kind)])
                                           (and (pair? mine)
                                                (make-%group (format "~a: ~a" (%kind-title kind) (buffers:name (outline:buffer o)))
                                                      kind mine))))
                                       outlines of-kinds)))
                              (%kind-order)))]
               [question (if root
                             (format "Go to item (~a ~a, Project ~a): " (length taken) (%buffers-word taken) (%root-name root))
                             (format "Go to item (~a ~a): " (length taken) (%buffers-word taken)))]
               [choice (%read question groups candidates view)])
          (jump-history:jump-to (outline:buffer (car choice)) (%place choice 'outline-picker:project-entry)))))))

(for-each (lambda (k) (tables:set! narrow-characters (car k) (cdr k)))
  '((class . #\c) (struct . #\s) (interface . #\i) (enum . #\e) (function . #\f) (method . #\m) (constructor . #\n)
    (macro . #\x) (property . #\p) (field . #\d) (variable . #\v) (constant . #\k) (module . #\M) (namespace . #\N)
    (package . #\P) (heading . #\h)))
(tables:set! completion:category-default-styles entry-category (list completion:any-order))
(keys:bind! keys:global "M-g i" entry)
(keys:bind! keys:global "M-g I" project-entry)
