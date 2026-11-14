#!tuna
(import (completion) (minibuffer) (commands) (keys) (modes) (buffers) (document) (views) (layout) (files) (jobs))

(define-saved buffer-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define-saved command-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define-saved file-name-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define-option grep-min-input 3 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many characters the search must hold before pickers:grep starts a job.")

(define-option grep-delay 0.2 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds without typing before pickers:grep starts a job.")

(define-option grep-max-file-size 1000000 (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "The largest file, in bytes, that pickers:grep reads.")

(define (%hidden? b)
  (let ([name (buffers:name b)])
    (and (fx> (string-length name) 0) (char=? (string-ref name 0) #\space))))

(define (%current-buffer)
  (let ([v (views:current)]) (and v (views:buffer v))))

(define (%buffer-preview view)
  (let ([before #f])
    (lambda (b)
      (cond
        [b
         (unless before (set! before (cons (views:buffer view) (views:point view))))
         (unless (eq? (views:buffer view) b) (views:set-buffer! view b))]
        [before
         (let ([shown (car before)] [point (cdr before)])
           (set! before #f)
           (when (and (buffers:live? shown) (not (eq? (views:buffer view) shown)))
             (views:set-buffer! view shown)
             (views:set-point! view point)))]))))

(define (buffers view)
  (unless (or (not view) (views:view? view))
    (assertion-violation 'pickers:buffers "neither a view nor #f" view))
  (let* ([current (%current-buffer)]
         [shown (remp %hidden? (buffers:all))]
         [ordered (if (memq current shown) (append (remq current shown) (list current)) shown)])
    (completion:source
      (candidates (list->vector (map (lambda (b) (cons (buffers:name b) b)) ordered)))
      (in-order)
      (title "Buffers")
      (category completion:buffer-category)
      (preview (and view (%buffer-preview view))))))

(define-option buffer-sources (list buffers) (lambda (v) (and (list? v) (for-all procedure? v)))
  "Procedures of a view, called by pickers:switch-to-buffer with the view it switches, each returning a source.")

(define read-buffer
  (case-lambda
    [(question) (read-buffer question buffer-history #f)]
    [(question h) (read-buffer question h #f)]
    [(question h default)
     (unless (or (not default) (buffers:buffer? default))
       (assertion-violation 'pickers:read-buffer "neither a buffer nor #f" default))
     (completion:read question (list (buffers #f)) h (and default (buffers:name default)))]))

(define (%private-name? name)
  (let* ([s (symbol->string name)] [n (string-length s)])
    (let loop ([i 0])
      (cond
        [(fx= i n) (and (fx> n 0) (char=? (string-ref s 0) #\%))]
        [(char=? (string-ref s i) #\:) (and (fx< (fx+ i 1) n) (char=? (string-ref s (fx+ i 1)) #\%))]
        [else (loop (fx+ i 1))]))))

(define (command-for-view? command view)
  (let ([modes (table-ref commands:command-modes command #f)])
    (or (not modes) (exists (lambda (mode) (modes:on? mode view)) modes))))

(define-option command-predicate command-for-view? procedure?
  "A procedure of a command and a view that says whether M-x offers the command while that view is selected.")

(define (%offered? command view)
  (and (commands:command? command) (or (not view) ((command-predicate) command view))))

(define (%read-command-from question h commands)
  (completion:read question
    (list (completion:source
            (candidates (list->vector (map (lambda (c) (cons (symbol->string (commands:command-name c)) c)) commands)))
            (category completion:command-category)))
    h))

(define read-command
  (case-lambda
    [(question) (read-command question command-history)]
    [(question h)
     (let ([view (views:current)])
       (%read-command-from question h
         (filter (lambda (c) (%offered? c view))
                 (map commands:command-named (remp %private-name? (commands:command-names))))))]))

(define (%bound-commands keymaps)
  (let ([found '()])
    (let walk ([keymaps keymaps] [seen '()])
      (for-each
        (lambda (keymap)
          (unless (memq keymap seen)
            (for-each
              (lambda (binding)
                (let ([v (cdr binding)])
                  (cond
                    [(table? v) (walk (list v) (cons keymap seen))]
                    [(and (commands:command? v) (not (memq v found))) (set! found (cons v found))])))
              (keys:bindings keymap))))
        keymaps))
    found))

(define (%mode-commands view)
  (let ([marked (filter (lambda (entry)
                          (and (pair? (cdr entry)) (exists (lambda (mode) (modes:on? mode view)) (cdr entry))))
                        (table-entries commands:command-modes))])
    (let loop ([cs (append (map car marked) (%bound-commands (modes:active-keymaps #f #f)))] [acc '()])
      (cond
        [(null? cs) (reverse acc)]
        [(and (%offered? (car cs) view) (not (memq (car cs) acc))) (loop (cdr cs) (cons (car cs) acc))]
        [else (loop (cdr cs) acc)]))))

(define (%home) (or (getenv "HOME") "/"))

(define (%expand path)
  (let ([n (string-length path)])
    (if (and (fx> n 0) (char=? (string-ref path 0) #\~) (or (fx= n 1) (char=? (string-ref path 1) #\/)))
        (string-append (%home) (substring path 1 n))
        path)))

(define (%abbreviate path)
  (let ([home (%home)])
    (let ([n (string-length home)])
      (if (and (fx> n 1) (fx>= (string-length path) n) (string=? (substring path 0 n) home)
               (or (fx= (string-length path) n) (char=? (string-ref path n) #\/)))
          (string-append "~" (substring path n (string-length path)))
          path))))

(define (%after-last-slash input)
  (let loop ([i (string-length input)])
    (cond
      [(fx= i 0) 0]
      [(char=? (string-ref input (fx- i 1)) #\/) i]
      [else (loop (fx- i 1))])))

(jobs:define-worker (%list-directory places emit receive)
  (import (completion matcher))
  (let ([home (car places)] [start (cdr places)])
    (define (expand prefix)
      (cond
        [(and (fx> (string-length prefix) 0) (char=? (string-ref prefix 0) #\~))
         (string-append home (substring prefix 1 (string-length prefix)))]
        [(and (fx> (string-length prefix) 0) (char=? (string-ref prefix 0) #\/)) prefix]
        [else (string-append start prefix)]))
    (define (directory? path) (guard (c [#t #f]) (file-directory? path)))
    (define (names dir) (guard (c [#t '()]) (list-sort string<? (directory-list (if (string=? dir "") "." dir)))))
    (define (entries dir shown)
      (map (lambda (name)
             (let ([path (string-append dir name)])
               (if (directory? path)
                   (cons (string-append shown name "/") (string-append path "/"))
                   (cons (string-append shown name) path))))
           (names dir)))
    (define (base-length prefix)
      (let loop ([i (fx- (string-length prefix) 1)])
        (cond
          [(fx< i 0) 0]
          [(and (char=? (string-ref prefix i) #\/) (directory? (expand (substring prefix 0 (fx+ i 1))))) (fx+ i 1)]
          [else (loop (fx- i 1))])))
    (define (components text)
      (let loop ([cs (string->list text)] [part '()] [acc '()])
        (cond
          [(null? cs) (reverse (if (null? part) acc (cons (list->string (reverse part)) acc)))]
          [(char=? (car cs) #\/) (loop (cdr cs) '() (if (null? part) acc (cons (list->string (reverse part)) acc)))]
          [else (loop (cdr cs) (cons (car cs) part) acc)])))
    (define (expansions n prefix)
      (fold-left
        (lambda (found component)
          (let ([matches? (pattern-matcher (partial-pattern component))])
            (apply append
              (map (lambda (dir)
                     (let ([path (car dir)] [shown (cdr dir)])
                       (map (lambda (name) (cons (string-append path name "/") (string-append shown name "/")))
                            (filter (lambda (name) (and (matches? name) (directory? (string-append path name))))
                                    (names path)))))
                   found))))
        (list (cons (expand (substring prefix 0 n)) ""))
        (components (substring prefix n (string-length prefix)))))
    (let loop ([prefix (receive)])
      (emit 'clear)
      (if (or (string=? prefix "") (directory? (expand prefix)))
          (emit (list->vector (entries (expand prefix) "")))
          (let ([n (base-length prefix)])
            (emit (list 'base n))
            (emit (list->vector (apply append (map (lambda (dir) (entries (car dir) (cdr dir))) (expansions n prefix)))))))
      (loop (receive)))))

(define (%default-directory)
  (let* ([b (%current-buffer)] [path (and b (files:path b))])
    (if path
        (substring path 0 (%after-last-slash path))
        (string-append (%home) "/"))))

(define read-file-name
  (case-lambda
    [(question) (read-file-name question (%default-directory) file-name-history)]
    [(question directory) (read-file-name question directory file-name-history)]
    [(question directory h)
     (unless (string? directory)
       (assertion-violation 'pickers:read-file-name "not a string" directory))
     (let* ([dir (%expand directory)]
            [dir (if (and (fx> (string-length dir) 0) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
                     dir
                     (string-append dir "/"))])
       (%expand
         (minibuffer:call-with-setup
           (lambda (p) (minibuffer:set-input! p (%abbreviate dir)))
           (lambda ()
             (completion:read-or-input question
               (list (completion:source
                       (job %list-directory (cons (%home) dir))
                       (split %after-last-slash)
                       (category completion:file-category)))
               h)))))]))

(define (%line-candidates doc first last)
  (let ([n (fx+ (fx- last first) 1)])
    (let ([v (make-vector n)] [end (document:length doc)])
      (do ([k first (fx+ k 1)]) ((fx> k last) v)
        (let* ([start (document:line-start doc k)]
               [stop (if (fx< k (document:line doc (fx- end 1))) (fx- (document:line-start doc (fx+ k 1)) 1) (fx- end 1))])
          (vector-set! v (fx- k first) (cons (document:text doc start (fxmax start stop)) start)))))))

(jobs:define-worker (%split-lines doc emit receive)
  (import (document))
  (let* ([end (fx- (document:length doc) 1)] [final (document:line doc end)]
         [last (if (and (fx> final 1) (fx= (document:line-start doc final) end)) (fx- final 1) final)])
    (let loop ([k 1])
      (when (fx<= k last)
        (let ([to (fxmin last (fx+ k 999))])
          (emit (let ([v (make-vector (fx+ (fx- to k) 1))])
                  (do ([j k (fx+ j 1)]) ((fx> j to) v)
                    (let* ([start (document:line-start doc j)]
                           [stop (if (fx< j final) (fx- (document:line-start doc (fx+ j 1)) 1) end)])
                      (vector-set! v (fx- j k) (cons (document:text doc start (fxmax start stop)) start))))))
          (loop (fx+ to 1)))))))

;; The empty run after a final newline is no line to go to.
(define (%last-line doc)
  (let* ([end (fx- (document:length doc) 1)] [last (document:line doc end)])
    (if (and (fx> last 1) (fx= (document:line-start doc last) end)) (fx- last 1) last)))

;; Matches the main thread's limit, so a buffer completion would match
;; there is split there too.
(define (%small? doc)
  (and (fx<= (document:length doc) 50000) (fx<= (document:line doc (fx- (document:length doc) 1)) 1000)))

(define (%read-line)
  (let* ([view (views:current)] [doc (buffers:document (views:buffer view))] [point (views:point view)])
    (completion:read "Go to line: "
      (list (if (%small? doc)
                (completion:source
                  (candidates (%line-candidates doc 1 (%last-line doc)))
                  (in-order)
                  (preview (lambda (p) (views:set-point! view (or p point)))))
                (completion:source
                  (job %split-lines doc)
                  (in-order)
                  (preview (lambda (p) (views:set-point! view (or p point))))))))))

(jobs:define-worker (%grep options emit receive)
  (import (completion matcher))
  (let ([root (vector-ref options 0)] [minimum (vector-ref options 1)] [delay (vector-ref options 2)]
        [max-size (vector-ref options 3)])
    (define (search-of prefix)
      (let ([n (string-length prefix)])
        (if (and (fx> n 0) (char=? (string-ref prefix (fx- n 1)) #\#)) (substring prefix 0 (fx- n 1)) prefix)))
    (define (components s)
      (let loop ([cs (string->list s)] [current '()] [acc '()])
        (define (finish) (if (null? current) acc (cons (list->string (reverse current)) acc)))
        (cond
          [(null? cs) (reverse (finish))]
          [(and (char=? (car cs) #\\) (pair? (cdr cs)) (char=? (cadr cs) #\space))
           (loop (cddr cs) (cons #\space current) acc)]
          [(char=? (car cs) #\space) (loop (cdr cs) '() (finish))]
          [else (loop (cdr cs) (cons (car cs) current) acc)])))
    (define (binary? bv)
      (let ([n (fxmin 8192 (bytevector-length bv))])
        (let loop ([i 0]) (and (fx< i n) (or (fx= (bytevector-u8-ref bv i) 0) (loop (fx+ i 1)))))))
    (define (read-text path)
      (guard (c [#t #f])
        (let ([p (open-file-input-port path)])
          (dynamic-wind
            void
            (lambda ()
              (and (<= (port-length p) max-size)
                   (let ([bv (get-bytevector-all p)])
                     (cond
                       [(eof-object? bv) ""]
                       [(binary? bv) #f]
                       [else (utf8->string bv)]))))
            (lambda () (close-port p))))))
    (define (lines-of text)
      (let loop ([i 0] [start 0] [acc '()])
        (cond
          [(fx= i (string-length text))
           (reverse (if (fx< start i) (cons (substring text start i) acc) acc))]
          [(char=? (string-ref text i) #\newline) (loop (fx+ i 1) (fx+ i 1) (cons (substring text start i) acc))]
          [else (loop (fx+ i 1) start acc)])))
    (define (walk! matches?)
      (call/cc
        (lambda (k)
          (let visit ([dir root] [shown ""])
            (for-each
              (lambda (name)
                (unless (char=? (string-ref name 0) #\.)
                  (let ([path (string-append dir "/" name)] [rel (string-append shown name)])
                    (let ([newer (receive 0)])
                      (unless (eof-object? newer) (k newer)))
                    (cond
                      [(guard (c [#t #t]) (file-symbolic-link? path)) (void)]
                      [(guard (c [#t #f]) (file-directory? path)) (visit path (string-append rel "/"))]
                      [else
                       (let ([text (read-text path)])
                         (when text
                           (let loop ([lines (lines-of text)] [n 1] [found '()])
                             (cond
                               [(null? lines) (unless (null? found) (emit (list->vector (reverse found))))]
                               [(matches? (car lines))
                                (loop (cdr lines) (fx+ n 1)
                                      (cons (cons (string-append rel ":" (number->string n) ":" (car lines))
                                                  (cons path n))
                                            found))]
                               [else (loop (cdr lines) (fx+ n 1) found)]))))]))))
              (guard (c [#t '()]) (list-sort string<? (directory-list dir)))))
          #f)))
    (define (settle prefix)
      (let ([next (receive delay)])
        (if (eof-object? next) prefix (settle next))))
    (let loop ([prefix (receive)] [last-search #f])
      (let* ([prefix (settle prefix)] [search (search-of prefix)])
        (if (equal? search last-search)
            (loop (receive) search)
            (begin
              (emit 'clear)
              (let ([newer (and (fx>= (string-length search) minimum)
                                (let ([terms (map (lambda (c) (list 'contains c)) (components search))])
                                  (and (pair? terms) (walk! (pattern-matcher terms)))))])
                (if newer (loop newer #f) (loop (receive) search)))))))))

(define (%grep-split input)
  (let loop ([i 0])
    (cond
      [(fx= i (string-length input)) i]
      [(char=? (string-ref input i) #\#) (fx+ i 1)]
      [else (loop (fx+ i 1))])))

(define (%grep-root)
  (let ([dir (%default-directory)])
    (if (and (fx> (string-length dir) 1) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
        (substring dir 0 (fx- (string-length dir) 1))
        dir)))

(define (%read-location)
  (completion:read "Grep: "
    (list (completion:source
            (job %grep (vector (%grep-root) (grep-min-input) (grep-delay) (grep-max-file-size)))
            (split %grep-split)
            (category completion:location-category)))))

(commands:define-command (execute-extended-command [command (read-command "M-x ")])
  "Runs COMMAND, read by name, passing the prefix argument on."
  (commands:run command))

(commands:define-command (execute-mode-command
                           [command (let ([view (views:current)])
                                      (if view
                                          (%read-command-from "M-X " command-history (%mode-commands view))
                                          (read-command "M-X ")))])
  "Runs COMMAND, read by name from the commands for the modes on in the selected view."
  (commands:run command))

(commands:define-command (switch-to-buffer [buffer (%read-switch)])
  "Shows BUFFER in the selected view."
  (layout:switch-to-buffer buffer))

(define (%read-switch)
  (let* ([view (views:current)]
         [v (completion:read-or-input "Switch to buffer: " (map (lambda (p) (p view)) (buffer-sources)) buffer-history)])
    (cond
      [(buffers:buffer? v) v]
      [(and (pair? v) (string? (car v))) (files:visit (car v))]
      [else (or (buffers:find v) (buffers:make v ""))])))

(commands:define-command (kill-buffer [buffer (read-buffer "Kill buffer: " buffer-history (%current-buffer))])
  "Kills BUFFER."
  (buffers:kill! buffer)
  (void))

(commands:define-command (line [position (%read-line)])
  "Moves point to POSITION, the start of a line read from the current buffer."
  (views:set-point! (views:current) position))

(commands:define-command (grep [location (%read-location)])
  "Visits LOCATION, a line read from the files under the current buffer's directory."
  (let ([b (files:visit (car location))])
    (layout:switch-to-buffer b)
    (let ([doc (buffers:document b)])
      (views:set-point! (views:current)
        (document:line-start doc (fxmax 1 (fxmin (cdr location) (document:line doc (fx- (document:length doc) 1)))))))))

(keys:bind! keys:global "M-x" execute-extended-command)
(keys:bind! keys:global "M-X" execute-mode-command)
(keys:bind! keys:global "C-x b" switch-to-buffer)
(keys:bind! keys:global "C-x k" kill-buffer)
(keys:bind! keys:global "M-s l" line)
(keys:bind! keys:global "M-s g" grep)
(set-option! files:file-name-reader read-file-name)
(table-set! completion:category-styles completion:file-category (list completion:partial completion:any-order))
