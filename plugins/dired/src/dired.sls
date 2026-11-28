#!tuna
(import (buffers) (document) (views) (keys) (commands) (modes) (editing) (kill-ring) (layout) (ui)
        (files) (jobs) (ask) (web) (haml) (completion) (files attributes) (dired reading) (hooks) (options) (tables) (saved))

(define %self (current-owner))

(define-enumeration sorting (name time size extension) %sortings)

(define-enumeration recursion (never top always) %recursions)

(define-enumeration column (mode links owner group size time) %columns)

(define (%names-of names) (enum-set->list (enum-set-universe names)))

(define (%one-of names)
  (lambda (v) (and (memq v (%names-of names)) #t)))

(define (%columns? v)
  (and (list? v)
       (for-all (lambda (c) (memq c (%names-of (%columns)))) v)
       (let loop ([v v]) (or (null? v) (and (not (memq (car v) (cdr v))) (loop (cdr v)))))))

(options:define-option sort (sorting name) (%one-of (%sortings))
  "How entries are ordered: name, time, size or extension, given with dired:sorting.")

(options:define-option reverse-sort? #f boolean?
  "When true, entries are in the reverse of dired:sort's order.")

(options:define-option folders-first? #f boolean?
  "When true, folders come before other entries.")

(options:define-option columns (list (column mode) (column links) (column owner) (column group) (column size) (column time))
  %columns?
  "The columns drawn before each name, in order, each given with dired:column.")

(options:define-option free-space? #t boolean?
  "When true, the header gives the space available on the folder's file system.")

(options:define-option deletion-confirmer ask:yes-or-no? procedure?
  "The procedure of a question that asks whether to delete; deletion goes on when it returns true.")

(options:define-option recursive-deletes (recursion top) (%one-of (%recursions))
  "Whether a folder that holds files is deleted: never, top asking for each, or always.")

(options:define-option recursive-copies (recursion top) (%one-of (%recursions))
  "Whether a folder is copied with everything in it: never, top asking for each, or always.")

(options:define-option other-listing-target? #f boolean?
  "When true and another view shows a listing, renaming and copying start in its folder: the first such view after the selected one, in layout:views order, cyclically.")

(options:define-option refresh-when-revisited? #f boolean?
  "When true, visiting a listing whose folder changed since it was read reads it again.")

(hooks:define-hook after-read "Called with a listing, current, after each read of its folder.")

(hooks:define-hook mode-hook "Called in each listing when its mode is set.")

(tables:define-table keymap "Keys in folder listings.")

(tables:define-table name-keymap "Keys on an entry's name, for clicks.")

(saved:define-saved %folders '() (lambda (v) (and (list? v) (for-all string? v))))

(modes:define-major-mode mode (parent modes:special) (lighter "Folder") (keymap keymap) (hook mode-hook) (plugin-only #t))

(modes:define-minor-mode hide-details?
  "When true, a listing draws only marks and names."
  (majors mode))

;; Kinds are compared by name, which a document keeps after the module
;; that defined them unloads.
(define %listing-kind 'dired:%listing)
(define %folder-kind 'dired:%folder)
(define %entry-kind 'dired:%entry)

(define (%with-slash folder)
  (let ([n (string-length folder)])
    (if (and (fx> n 0) (char=? (string-ref folder (fx- n 1)) #\/))
        folder
        (string-append folder "/"))))

(define (%home) (%with-slash (or (getenv "HOME") "/")))

(define (%parent-folder path)
  (let ([n (string-length path)])
    (if (and (fx> n 1) (char=? (string-ref path (fx- n 1)) #\/))
        (%with-slash (path-parent (substring path 0 (fx- n 1))))
        (%with-slash (path-parent path)))))

;; A name's leading dot starts no extension, as Emacs's
;; file-name-extension reads one.
(define (%extension name)
  (let loop ([i (fx- (string-length name) 1)])
    (cond
      [(fx<= i 0) ""]
      [(char=? (string-ref name i) #\.) (substring name (fx+ i 1) (string-length name))]
      [else (loop (fx- i 1))])))

(jobs:define-worker (%resolver path emit)
  (import (dired reading))
  (emit (resolve-folder path)))

(jobs:define-worker (%reader folder emit)
  (import (dired reading))
  (emit (read-folder folder)))

(jobs:define-worker (%state-reader folder emit)
  (import (dired reading))
  (emit (folder-state folder)))

(jobs:define-worker (%non-empty-folders paths emit)
  (import (dired reading))
  (emit (non-empty-folders paths)))

(module %internals
  (job-result stop-waiting!)

  ;; Unloading this module stops its jobs without ending them, so it
  ;; resumes the tasks waiting for them itself.
  (define waiting '())

  (define (take-waiter! w)
    (and (memq w waiting)
         (begin (set! waiting (remq w waiting)) #t)))

  (define (failure-condition who f)
    (let ([irritants (map (lambda (x) (if (string? x) (files:abbreviated-path x) x)) (failure-irritants f))])
      (condition (make-i/o-error) (make-who-condition who)
                 (make-message-condition (if (failure-format? f) (apply format (failure-message f) irritants) (failure-message f)))
                 (make-irritants-condition (if (failure-format? f) '() irritants)))))

  (define (job-result who worker input)
    (let ([job #f] [result #f])
      (guard (c [#t (when job (jobs:stop! job)) (raise c)])
        (suspend
          (lambda (resume)
            (let ([w (cons who resume)])
              (call-as-owner %self
                (lambda ()
                  (set! job
                    (jobs:start worker input
                      (lambda (v) (set! result v))
                      (lambda (ended)
                        (when (take-waiter! w)
                          (resume
                            (lambda ()
                              (cond
                                [(condition? ended) (raise ended)]
                                [ended (assertion-violation who "the job was stopped")]
                                [(failure? result) (raise (failure-condition who result))])
                              result))))))))
              (set! waiting (cons w waiting))))))))

  (define (stop-waiting!)
    (let ([stopped waiting])
      (set! waiting '())
      (for-each (lambda (w)
                  ((cdr w)
                   (lambda ()
                     (raise (condition (make-error) (make-who-condition (car w))
                                       (make-message-condition "the dired plugin was unloaded"))))))
                stopped))))

(import %internals)

(define (%check-buffer who b)
  (unless (buffers:buffer? b)
    (assertion-violation who "not a buffer" b)))

(define (%check-view who view)
  (unless (and (views:view? view) (views:buffer view))
    (assertion-violation who "not a view showing a buffer" view)))

(define (%check-entry who entry)
  (unless (and (document:node? entry) (eq? (document:node-kind entry) %entry-kind))
    (assertion-violation who "not an entry" entry)))

(define (%check-paths who paths)
  (unless (and (list? paths) (pair? paths) (for-all string? paths))
    (assertion-violation who "not a list of paths" paths)))

(define (%folder-node doc)
  (and (fx> (document:length doc) 2)
       (let ([root (document:token doc 0)] [folder (document:token doc 1)])
         (and (document:node? root) (eq? (document:node-kind root) %listing-kind)
              (document:node? folder) (eq? (document:node-kind folder) %folder-kind)
              folder))))

(define (folder buffer)
  (%check-buffer 'dired:folder buffer)
  (and (buffers:live? buffer)
       (let ([node (%folder-node (buffers:document buffer))])
         (and node (document:node-attribute node 'path)))))

(define (%listing-of folder-path)
  (find (lambda (b) (equal? (folder b) folder-path)) (buffers:all)))

(define (%listings) (filter folder (buffers:all)))

(define (%check-listing who b)
  (%check-buffer who b)
  (unless (folder b)
    (assertion-violation who "not a listing" b)))

(define (%remember-folders!)
  (saved:set! %folders (map folder (%listings))))

(define (%children node)
  (let ([acc '()])
    (document:for-each-child node (document:node-start node) (document:node-end node)
      (lambda (child at) (when (document:node? child) (set! acc (cons child acc)))))
    (reverse acc)))

(define (%entries b)
  (let ([node (%folder-node (buffers:document b))])
    (if node (filter (lambda (n) (eq? (document:node-kind n) %entry-kind)) (%children node)) '())))

(define (%entry-name entry) (document:node-attribute entry 'key))

(define (%trivial? entry) (member (%entry-name entry) '("." "..")))

(define (%entry-containing doc p)
  (let loop ([node (document:enclosing doc p)])
    (cond
      [(not node) #f]
      [(eq? (document:node-kind node) %entry-kind) node]
      [else (loop (document:enclosing doc (document:node-start node)))])))

(define (entry-at view)
  (%check-view 'dired:entry-at view)
  (%entry-containing (buffers:document (views:buffer view)) (views:point view)))

(define (entry-path entry)
  (%check-entry 'dired:entry-path entry)
  (document:node-attribute entry 'path))

(define (entry-mark entry)
  (%check-entry 'dired:entry-mark entry)
  (document:node-attribute entry 'mark))

(define (entry-attributes entry)
  (%check-entry 'dired:entry-attributes entry)
  (document:node-attribute entry 'attributes))

(define (%name-start entry) (fx+ (document:node-start entry) 1))

(define (%next-entry doc entry)
  (let ([t (document:token doc (document:node-end entry))])
    (and (document:node? t) (eq? (document:node-kind t) %entry-kind) t)))

(define (%previous-entry doc entry)
  (let ([p (document:node-start entry)])
    (and (fx> p 0) (%entry-containing doc (fx- p 1)))))

;; A negative count leaves the entry at point out, as Dired's repeated
;; commands do, so DEL unmarks the entry above rather than the one at point.
(define (%entries-from doc at n)
  (let ([step (if (fx> n 0) %next-entry %previous-entry)])
    (let loop ([entry (if (fx> n 0) at (and at (%previous-entry doc at)))] [k (abs n)] [acc '()])
      (if (or (fx= k 0) (not entry))
          (reverse acc)
          (loop (step doc entry) (fx- k 1) (cons entry acc))))))

(define (%first-entry doc)
  (let ([folder (%folder-node doc)])
    (and folder
         (find (lambda (n) (eq? (document:node-kind n) %entry-kind)) (%children folder)))))

(define (%entry-datum folder-path name attributes broken mark)
  (%entry (list (cons 'key name) (cons 'path (string-append folder-path name)) (cons 'attributes attributes)
                (cons 'broken broken) (cons 'mark mark))
          (string-append name "\n")))

(define (%header-datum folder-path used available)
  (apply %header (list (cons 'key 'header) (cons 'used used) (cons 'available available))
    (append (%path-links folder-path) (list "\n"))))

(define (%path-links folder-path)
  (let* ([shown (files:abbreviated-path folder-path)]
         [home? (and (fx> (string-length shown) 0) (char=? (string-ref shown 0) #\~))]
         [start (if home? (%home) "/")]
         [parts (let loop ([chars (string->list (substring shown (if home? 2 1) (string-length shown)))] [part '()] [acc '()])
                  (cond
                    [(null? chars) (reverse (if (null? part) acc (cons (list->string (reverse part)) acc)))]
                    [(char=? (car chars) #\/) (loop (cdr chars) '() (if (null? part) acc (cons (list->string (reverse part)) acc)))]
                    [else (loop (cdr chars) (cons (car chars) part) acc)]))])
    (let loop ([parts parts] [at start] [acc (list (%folder-link (list (cons 'path start)) (if home? "~/" "/")))])
      (if (null? parts)
          (reverse acc)
          (let ([at (string-append at (car parts) "/")])
            (loop (cdr parts) at (cons* "/" (%folder-link (list (cons 'path at)) (car parts)) acc)))))))

(define (%name<? a b)
  (or (string-ci<? a b) (and (string-ci=? a b) (string<? a b))))

(define (%sorted buffer entries)
  (let-values ([(order reverse? folders-first?)
                (buffers:with-buffer buffer (values (sort) (reverse-sort?) (folders-first?)))])
    (define name listed-name)
    (define attributes listed-attributes)
    (define (by key greater?)
      (lambda (a b)
        (let ([ka (key a)] [kb (key b)])
          (cond
            [(greater? ka kb) #t]
            [(greater? kb ka) #f]
            [else (%name<? (name a) (name b))]))))
    (define (folder? e) (eq? (file-attributes-type (attributes e)) (file-type folder)))
    (let* ([before (case order
                     [(time) (by (lambda (e) (file-attributes-modified (attributes e))) >)]
                     [(size) (by (lambda (e) (file-attributes-size (attributes e))) >)]
                     [(extension) (by (lambda (e) (%extension (name e))) (lambda (x y) (%name<? x y)))]
                     [else (lambda (a b) (%name<? (name a) (name b)))])]
           [sorted (list-sort before entries)]
           [sorted (if reverse? (reverse sorted) sorted)])
      (if folders-first?
          (append (filter folder? sorted) (remp folder? sorted))
          sorted))))

(define (%widths entries)
  (map (lambda (c)
         (cons c (fold-left (lambda (w e) (fxmax w (string-length (%column-text c (listed-attributes e))))) 0 entries)))
       (%names-of (%columns))))

(define (%folder-datum b folder-path read marks)
  (let* ([entries (vector->list (folder-read-entries read))]
         [sorted (append (list-head entries 2) (%sorted b (list-tail entries 2)))])
    (apply %folder (list (cons 'key 'folder) (cons 'path folder-path)
                         (cons 'modified (modification-stamp (folder-read-attributes read)))
                         (cons 'widths (%widths entries)))
      (%header-datum folder-path
                     (fold-left (lambda (n e) (+ n (* 512 (file-attributes-blocks (listed-attributes e))))) 0 entries)
                     (folder-read-space read))
      (map (lambda (e)
             (%entry-datum folder-path (listed-name e) (listed-attributes e) (listed-broken? e) (marks (listed-name e))))
           sorted))))

(define (%protect! b)
  (let ([n (document:length (buffers:document b))])
    (buffers:set-spans! (buffers:layer b %read-only) 0 n (list (list 0 n '())))))

;; Marks are read just before the write, so a mark set while the job read
;; is kept. A mark carried to a path, as a copy's or a renamed file's,
;; comes before a mark the name already had.
(define (%marks-of b)
  (let ([marks (make-hashtable string-hash string=?)])
    (for-each (lambda (e) (let ([m (document:node-attribute e 'mark)]) (when m (hashtable-set! marks (%entry-name e) m))))
              (%entries b))
    (lambda (name) (hashtable-ref marks name #f))))

(define (%with-carried-marks folder-path carried marks)
  (lambda (name)
    (or (hashtable-ref carried (string-append folder-path name) #f) (marks name))))

(define (%no-carried-marks) (make-hashtable string-hash string=?))

(define (%points b)
  (map (lambda (view)
         (let ([entry (%entry-containing (buffers:document b) (views:point view))])
           (list view
                 (and entry (%entry-name entry))
                 (and entry (fx- (views:point view) (%name-start entry))))))
       (views:showing b)))

(define (%restore-points! b points)
  (for-each
    (lambda (p)
      (let ([view (car p)] [name (cadr p)])
        (when name
          (let ([entry (find (lambda (e) (equal? (%entry-name e) name)) (%entries b))])
            (when entry
              (views:set-point! view
                (fxmin (fx+ (%name-start entry) (caddr p)) (fx- (document:node-end entry) 2))))))))
    points))

;; Entries that keep their order are reconciled, so a read keeps their
;; history; a new order, as after a sort, would make every entry a change
;; of its own, so the folder is written whole.
(define (%reordered? b datum)
  (let ([old (make-hashtable string-hash string=?)] [new (make-hashtable string-hash string=?)])
    (for-each (lambda (e) (hashtable-set! old (%entry-name e) #t)) (%entries b))
    (let ([new-names (filter (lambda (name) (hashtable-contains? old name))
                             (map (lambda (child) (cdr (assq 'key (cadr child)))) (cdddr datum)))])
      (for-each (lambda (name) (hashtable-set! new name #t)) new-names)
      (not (equal? new-names
                   (filter (lambda (name) (hashtable-contains? new name)) (map %entry-name (%entries b))))))))

(define (%write-read! b read carried)
  (let* ([folder-path (folder b)] [points (%points b)]
         [datum (%folder-datum b folder-path read (%with-carried-marks folder-path carried (%marks-of b)))])
    (buffers:with-silent-edits b
      (if (%reordered? b datum)
          (let ([node (%folder-node (buffers:document b))])
            (buffers:splice! b (document:node-start node) (document:node-end node) (document:from-datum datum)))
          (buffers:reconcile! b (document:token (buffers:document b) 0) (list datum))))
    (%protect! b)
    (%restore-points! b points)
    (buffers:with-buffer b (after-read b))))

(define (%make-listing! folder-path read)
  (let ([b (buffers:make (files:abbreviated-path folder-path) (%listing '()))])
    (buffers:with-silent-edits b
      (buffers:reconcile! b (document:token (buffers:document b) 0)
        (list (%folder-datum b folder-path read (lambda (name) #f)))))
    (modes:set-major-mode mode b)
    (%protect! b)
    (%remember-folders!)
    (buffers:with-buffer b (after-read b))
    b))

(define (%check-task who)
  (unless (current-task)
    (assertion-violation who "not in a task")))

(define (%read-at? listing state)
  (and (eqv? (state-stamp state) (document:node-attribute (%folder-node (buffers:document listing)) 'modified))
       (equal? (state-names state) (list-sort string<? (map %entry-name (remp %trivial? (%entries listing)))))))

;; A folder that is gone is no change, so a listing of it is not read again
;; until the user asks.
(define (%stale? listing)
  (let ([state (guard (c [(i/o-error? c) #f]) (job-result 'dired:stale? %state-reader (folder listing)))])
    (and state (not (%read-at? listing state)))))

(define (visit folder-path)
  (unless (string? folder-path)
    (assertion-violation 'dired:visit "not a string" folder-path))
  (%check-task 'dired:visit)
  (let* ([found (job-result 'dired:visit %resolver folder-path)]
         [resolved (%with-slash (resolved-path found))] [modified (resolved-modified found)])
    (unless modified
      (raise (condition (make-i/o-filename-error resolved) (make-who-condition 'dired:visit)
                        (make-message-condition "not a folder") (make-irritants-condition (list (files:abbreviated-path resolved))))))
    (let ([b (%listing-of resolved)])
      (if b
          (begin
            (when (%stale? b)
              (if (buffers:with-buffer b (refresh-when-revisited?))
                  (refresh b)
                  (ask:message "Folder changed on disk; type g to refresh")))
            b)
          (let ([read (job-result 'dired:visit %reader resolved)])
            (or (%listing-of resolved) (%make-listing! resolved read)))))))

(define (%refresh! who buffer carried)
  (%check-listing who buffer)
  (%check-task who)
  (let* ([folder-path (folder buffer)]
         [read (guard (c [(i/o-error? c)
                          (raise (condition (make-i/o-filename-error folder-path) (make-who-condition who)
                                            (make-message-condition "no such folder")
                                            (make-irritants-condition (list (files:abbreviated-path folder-path)))))])
                 (job-result who %reader folder-path))])
    (when (and (buffers:live? buffer) (equal? (folder buffer) folder-path))
      (%write-read! buffer read carried))))

(commands:define-command (refresh [buffer (buffers:current)])
  "Reads the folder of the listing BUFFER again, keeping marks and points."
  (%refresh! 'dired:refresh buffer (%no-carried-marks)))

(define (%refresh-folders! folders carried)
  (for-each
    (lambda (f)
      (let ([b (%listing-of f)])
        (when b
          (guard (c [(and (i/o-error? c) (not (cancelled? c))) (void)])
            (%refresh! 'dired:refresh b carried)))))
    (let loop ([fs folders] [acc '()])
      (cond
        [(null? fs) (reverse acc)]
        [(member (car fs) acc) (loop (cdr fs) acc)]
        [else (loop (cdr fs) (cons (car fs) acc))]))))

(define (place-point! view)
  (%check-view 'dired:place-point! view)
  (%check-listing 'dired:place-point! (views:buffer view))
  (let* ([b (views:buffer view)]
         [entry (or (find (lambda (e) (not (%trivial? e))) (%entries b)) (%first-entry (buffers:document b)))])
    (when entry
      (views:set-point! view (%name-start entry)))))

;; A view shows a buffer from its first stop, which in a listing is ., so
;; point there or on .. has not been placed.
(define (%place-point! view)
  (let ([at (%entry-containing (buffers:document (views:buffer view)) (views:point view))])
    (when (or (not at) (%trivial? at))
      (place-point! view))))

(define (%point-on! view path)
  (let ([entry (find (lambda (e) (equal? (document:node-attribute e 'path) path)) (%entries (views:buffer view)))])
    (if entry
        (views:set-point! view (%name-start entry))
        (%place-point! view))))

(define (%show-listing! b)
  (layout:switch-to-buffer b)
  (let ([view (layout:selected-view)])
    (when (eq? (views:buffer view) b)
      (%place-point! view))))

(define (%path-of-point who)
  (let* ([view (views:current)] [entry (and view (views:buffer view) (entry-at view))])
    (unless entry
      (error who "no file on this line"))
    (entry-path entry)))

(commands:define-command (open [folder-path (ask:file-name "Folder: " (files:directory))])
  "Shows the listing of FOLDER-PATH in the selected view."
  (%show-listing! (visit folder-path)))

(define (%show-at! b path)
  (layout:switch-to-buffer b)
  (let ([view (layout:selected-view)])
    (when (eq? (views:buffer view) b)
      (%point-on! view path))))

(commands:define-command (jump [buffer (buffers:current)])
  "Shows the listing of the folder holding BUFFER's file, with point on it; for a listing, its parent's listing, with point on its folder."
  (%check-buffer 'dired:jump buffer)
  (let ([listed (folder buffer)] [file (files:path buffer)])
    (cond
      [listed (%show-at! (visit (%parent-folder listed)) (substring listed 0 (fx- (string-length listed) 1)))]
      [file (%show-at! (visit (%with-slash (path-parent file))) file)]
      [else (%show-listing! (visit (files:directory buffer)))])))

(commands:define-command (up [buffer (buffers:current)])
  "Shows the listing of the parent of the folder the listing BUFFER lists, with point on that folder."
  (%check-listing 'dired:up buffer)
  (let ([listed (folder buffer)])
    (%show-at! (visit (%parent-folder listed)) (substring listed 0 (fx- (string-length listed) 1)))))

(commands:define-command (find-file [path (%path-of-point 'dired:find-file)])
  "Visits PATH and shows its buffer in the selected view; a folder shows its listing."
  (unless (string? path)
    (assertion-violation 'dired:find-file "not a string" path))
  (let ([b (files:visit path)])
    (if (folder b) (%show-listing! b) (layout:switch-to-buffer b))))

(define (%display-path! path select?)
  (let* ([b (files:visit path)] [view (layout:display-buffer b)])
    (when (folder b) (%place-point! view))
    (when select? (layout:select! view))))

(commands:define-command (find-file-other-view [path (%path-of-point 'dired:find-file-other-view)])
  "Visits PATH, shows its buffer in another view and selects that view."
  (unless (string? path)
    (assertion-violation 'dired:find-file-other-view "not a string" path))
  (%display-path! path #t))

(commands:define-command (display-file [path (%path-of-point 'dired:display-file)])
  "Visits PATH and shows its buffer in another view, leaving the listing's view selected."
  (unless (string? path)
    (assertion-violation 'dired:display-file "not a string" path))
  (%display-path! path #f))

(commands:define-command (mouse-find-file [event (keys:command-event)])
  "Visits the entry clicked, shows it in another view and selects that view."
  (unless (keys:event? event)
    (assertion-violation 'dired:mouse-find-file "not a mouse event" event))
  (let* ([posn (keys:event-start event)] [view (views:posn-view posn)] [p (views:posn-point posn)]
         [entry (and view p (views:buffer view) (%entry-containing (buffers:document (views:buffer view)) p))])
    (unless entry
      (error 'dired:mouse-find-file "no file at the click"))
    (%display-path! (entry-path entry) #t)))

(commands:define-command (%follow-folder-link [link (ui:pushed-button)])
  "Shows the listing of the folder the header's link names."
  (%show-listing! (visit (document:node-attribute link 'path))))

(define (%check-count who n)
  (unless (and (integer? n) (exact? n))
    (assertion-violation who "not an exact integer" n)))

(define (%entry-after doc p n)
  (let ([entry (%entry-containing doc p)])
    (if entry
        (let loop ([entry entry] [n n])
          (cond
            [(fx= n 0) entry]
            [(fx> n 0) (let ([next (%next-entry doc entry)]) (if next (loop next (fx- n 1)) entry))]
            [else (let ([before (%previous-entry doc entry)]) (if before (loop before (fx+ n 1)) entry))]))
        (let ([first (%first-entry doc)])
          (and first (if (fx> n 0) (%entry-after doc (%name-start first) (fx- n 1)) first))))))

(define (%move-entries who n)
  (let ([view (views:current)])
    (editing:move-cursors! who view n
      (lambda (c doc lo hi)
        (let ([entry (%entry-after doc (views:cursor-point c) n)])
          (values (if entry (%name-start entry) (views:cursor-point c)) #f))))))

(commands:define-command (next-line [n (commands:prefix-number)])
  "Moves each cursor N entries down, to the start of the entry's name."
  (%check-count 'dired:next-line n)
  (%move-entries 'dired:next-line n))

(commands:define-command (previous-line [n (commands:prefix-number)])
  "Moves each cursor N entries up, to the start of the entry's name."
  (%check-count 'dired:previous-line n)
  (%move-entries 'dired:previous-line (- n)))

;; Only an entry's opening holds its mark, so a mark change rewrites the
;; opening alone and the name's text, points and anchors stay.
(define (%set-mark! b entry mark)
  (let ([start (document:node-start entry)])
    (buffers:splice! b start (fx+ start 1)
      (document:slice
        (document:from-datum
          (%entry (map (lambda (key) (cons key (if (eq? key 'mark) mark (document:node-attribute entry key))))
                       '(key path attributes broken mark))))
        0 1))))

(define (%check-mark who mark)
  (unless (or (not mark) (char? mark))
    (assertion-violation who "not a mark character or #f" mark)))

(define (%change-marks! b entries mark-of)
  (fold-left
    (lambda (n e)
      (let ([new (mark-of e)])
        (if (or (%trivial? e) (eqv? new (document:node-attribute e 'mark)))
            n
            (begin (%set-mark! b e new) (fx+ n 1)))))
    0 entries))

(define (mark-where! buffer predicate mark)
  (%check-listing 'dired:mark-where! buffer)
  (unless (procedure? predicate)
    (assertion-violation 'dired:mark-where! "not a procedure" predicate))
  (%check-mark 'dired:mark-where! mark)
  (%change-marks! buffer (filter predicate (%entries buffer)) (lambda (e) mark)))

(define (%region-entries view)
  (let ([mark (views:mark view)])
    (and mark
         (let* ([point (views:point view)] [lo (fxmin point mark)] [hi (fxmax point mark)])
           (filter (lambda (e) (and (fx< (%name-start e) hi) (fx> (fx- (document:node-end e) 1) lo)))
                   (%entries (views:buffer view)))))))

(define (%mark-entries! who n mark)
  (%check-count who n)
  (let* ([view (views:current)] [b (and view (views:buffer view))])
    (%check-listing who b)
    (let ([region (%region-entries view)])
      (if region
          (%change-marks! b region (lambda (e) mark))
          (let* ([doc (buffers:document b)]
                 [entries (%entries-from doc (%entry-containing doc (views:point view)) n)])
            (%change-marks! b entries (lambda (e) mark))
            (unless (null? entries)
              (let ([last (car (last-pair entries))])
                (views:set-point! view
                  (%name-start (or (and (fx> n 0) (%next-entry doc last)) last))))))))))

(commands:define-command (mark [n (commands:prefix-number)])
  "Marks the entry at point with * and moves to the next, N times, or every entry in the region."
  (%mark-entries! 'dired:mark n #\*))

(commands:define-command (unmark [n (commands:prefix-number)])
  "Removes the mark of the entry at point and moves to the next, N times, or of every entry in the region."
  (%mark-entries! 'dired:unmark n #f))

(commands:define-command (unmark-backward [n (commands:prefix-number)])
  "Moves to the entry above and removes its mark, N times."
  (%mark-entries! 'dired:unmark-backward (- n) #f))

(commands:define-command (flag-deletion [n (commands:prefix-number)])
  "Flags the entry at point with D and moves to the next, N times, or every entry in the region."
  (%mark-entries! 'dired:flag-deletion n #\D))

(commands:define-command (unmark-all [buffer (buffers:current)])
  "Removes every mark in the listing BUFFER."
  (%check-listing 'dired:unmark-all buffer)
  (%change-marks! buffer (%entries buffer) (lambda (e) #f))
  (void))

(commands:define-command (toggle-marks [buffer (buffers:current)])
  "Marks with * the unmarked entries of BUFFER and unmarks those marked *, or only the entries in the region."
  (%check-listing 'dired:toggle-marks buffer)
  (let* ([view (views:current)]
         [entries (or (and view (eq? (views:buffer view) buffer) (%region-entries view)) (%entries buffer))])
    (%change-marks! buffer entries
      (lambda (e)
        (case (document:node-attribute e 'mark)
          [(#f) #\*]
          [(#\*) #f]
          [else (document:node-attribute e 'mark)])))
    (void)))

(define (%mark-kind! who buffer predicate)
  (%check-listing who buffer)
  (let ([mark (if (commands:prefix-argument) #f #\*)])
    (%change-marks! buffer
      (filter (lambda (e) (predicate (document:node-attribute e 'attributes))) (%entries buffer))
      (lambda (e) mark))
    (void)))

(commands:define-command (mark-folders [buffer (buffers:current)])
  "Marks every folder of BUFFER with *; with a prefix argument, unmarks them."
  (%mark-kind! 'dired:mark-folders buffer
    (lambda (a) (eq? (file-attributes-type a) (file-type folder)))))

(commands:define-command (mark-links [buffer (buffers:current)])
  "Marks every symbolic link of BUFFER with *; with a prefix argument, unmarks them."
  (%mark-kind! 'dired:mark-links buffer
    (lambda (a) (eq? (file-attributes-type a) (file-type link)))))

(commands:define-command (mark-executables [buffer (buffers:current)])
  "Marks every file of BUFFER that some user may execute, folders left out, with *; with a prefix argument, unmarks them."
  (%mark-kind! 'dired:mark-executables buffer
    (lambda (a) (and (not (eq? (file-attributes-type a) (file-type folder)))
                     (not (fx= 0 (fxand (file-attributes-mode a) #o111)))))))

(define operation-paths
  (case-lambda
    [(view) (operation-paths view (commands:prefix-argument))]
    [(view prefix)
     (%check-view 'dired:operation-paths view)
     (let* ([b (views:buffer view)] [doc (buffers:document b)]
            [at (%entry-containing doc (views:point view))]
            [paths
             (map (lambda (e) (document:node-attribute e 'path))
               (remp %trivial?
                 (cond
                   [(and (fixnum? prefix) (not (fx= prefix 0))) (%entries-from doc at prefix)]
                   [(or (pair? prefix) (eq? prefix '-)) (if at (list at) '())]
                   [else
                    (let ([marked (filter (lambda (e) (eqv? (document:node-attribute e 'mark) #\*)) (%entries b))])
                      (cond
                        [(pair? marked) marked]
                        [at (list at)]
                        [else '()]))])))])
       (when (null? paths)
         (error 'dired:operation-paths "no file on this line"))
       paths)]))

(define %current-paths
  (case-lambda
    [(who) (%current-paths who (commands:prefix-argument))]
    [(who prefix)
     (let ([view (views:current)])
       (unless (and view (views:buffer view) (folder (views:buffer view)))
         (assertion-violation who "not in a listing"))
       (operation-paths view prefix))]))

(define (%name path) (path-last path))

(define (%count-text n) (if (= n 1) "1 file" (format "~a files" n)))

(define (%files-text paths)
  (if (null? (cdr paths)) (%name (car paths)) (format "* [~a]" (%count-text (length paths)))))

(define (%failure-text c)
  (if (message-condition? c)
      (let ([irritants (if (irritants-condition? c) (condition-irritants c) '())])
        (if (null? irritants) (condition-message c) (format "~a ~s" (condition-message c) irritants)))
      (format "~s" c)))

;; Each path is tried alone, so one failure leaves the others done. The
;; summary is returned, for the caller to say once the listings are read
;; again, as Dired removes the lines before it says it is done.
(define (%for-each-path! verb paths act!)
  (let ([done 0] [declined '()] [failures '()])
    (for-each
      (lambda (path)
        (guard (c [(not (cancelled? c)) (set! failures (cons (cons path c) failures))])
          (if (act! path)
              (set! done (fx+ done 1))
              (set! declined (cons path declined)))))
      paths)
    (let ([failures (reverse failures)] [declined (reverse declined)])
      (string-append
        (if (null? failures)
            (format "~a ~a" verb (%count-text done))
            (format "~a of ~a failed: ~{~a~^; ~}" (length failures) (%count-text (length paths))
                    (map (lambda (f) (format "~a: ~a" (%name (car f)) (%failure-text (cdr f)))) failures)))
        (if (null? declined)
            ""
            (format "; declined ~{~a~^, ~}" (map %name declined)))))))

(define (%show-names-while names thunk)
  (if (null? (cdr names))
      (thunk)
      (let* ([b (begin
                  (let ([old (buffers:find " *Deletions*")]) (when old (buffers:kill! old)))
                  (buffers:make " *Deletions*" (apply string-append (map (lambda (n) (string-append n "\n")) names))))]
             [selected (layout:selected-view)] [view (layout:display-buffer b)])
        ;; Tuna's dynamic-wind runs its out at each pause, and the question
        ;; pauses, so the names are taken away after the answer instead.
        (define (take-away!)
          (when (memq view (layout:views))
            (layout:select! view)
            (layout:quit-view)
            (when (memq selected (layout:views)) (layout:select! selected)))
          (when (buffers:live? b) (buffers:kill! b)))
        (let ([answer (guard (c [#t (take-away!) (raise c)]) (thunk))])
          (take-away!)
          answer))))

(define (%recursion-allowed? option question paths)
  (let ([folders (job-result 'dired:recursion %non-empty-folders paths)])
    (lambda (path)
      (or (not (member path folders))
          (case option
            [(never) (error 'dired "a folder that holds files" (files:abbreviated-path path))]
            [(always) #t]
            [else (ask:yes-or-no? (format question (%name path)))])))))

(define (%delete-paths! paths)
  (let* ([trash? (files:delete-by-moving-to-trash?)]
         [verb (if trash? "Trash" "Delete")])
    (if (%show-names-while (map %name paths)
          (lambda () ((deletion-confirmer) (format "~a ~a? " verb (%files-text paths)))))
        (let ([allowed? (%recursion-allowed? (recursive-deletes)
                          (if trash? "Recursively trash ~a? " "Recursively delete ~a? ") paths)])
          (let ([summary (%for-each-path! (if trash? "Trashed" "Deleted") paths
                           (lambda (path)
                             (and (allowed? path)
                                  (begin
                                    (if trash? (files:move-to-trash path) (files:delete-file path))
                                    #t))))])
            (%refresh-folders! (map %parent-folder paths) (%no-carried-marks))
            (ask:message summary)))
        (ask:message "(No deletions performed)"))))

(commands:define-command (delete [paths (%current-paths 'dired:delete)])
  "Asks, then deletes PATHS, or moves them to the trash when files:delete-by-moving-to-trash? is true."
  (%check-paths 'dired:delete paths)
  (%delete-paths! paths))

(commands:define-command (delete-flagged [buffer (buffers:current)])
  "Deletes the entries of the listing BUFFER flagged D."
  (%check-listing 'dired:delete-flagged buffer)
  (let ([paths (map (lambda (e) (document:node-attribute e 'path))
                    (filter (lambda (e) (eqv? (document:node-attribute e 'mark) #\D)) (%entries buffer)))])
    (if (null? paths)
        (ask:message "(No deletions requested)")
        (%delete-paths! paths))))

;; By the views after the selected one, as Emacs's dired-dwim-target-next
;; takes the next windows, rather than by which view was selected last.
(define (%target-folder)
  (let ([own (files:directory)])
    (or (and (other-listing-target?)
             (let* ([all (layout:views)] [from (memq (layout:selected-view) all)]
                    [next (if from (append (cdr from) (list-head all (fx- (length all) (length from)))) all)])
               (exists (lambda (view) (and (views:buffer view) (folder (views:buffer view)))) next)))
        own)))

(define (%target-question verb paths)
  (if (null? (cdr paths))
      (format "~a ~a to: " verb (%name (car paths)))
      (format "~a ~a to: " (if (string=? verb "Rename") "Move" verb) (%files-text paths))))

(define (%read-target who verb)
  (ask:file-name (%target-question verb (%current-paths who)) (%target-folder)))

(define (%expand path)
  (if (and (fx> (string-length path) 0) (char=? (string-ref path 0) #\~)
           (or (fx= (string-length path) 1) (char=? (string-ref path 1) #\/)))
      (string-append (%home) (substring path (if (fx= (string-length path) 1) 1 2) (string-length path)))
      path))

(define (%targets who paths target)
  (let ([target (%expand target)])
    (if (or (pair? (cdr paths)) (file-directory? target) (char=? (string-ref target (fx- (string-length target) 1)) #\/))
        (begin
          (unless (file-directory? target)
            (error who "not a folder" (files:abbreviated-path target)))
          (map (lambda (p) (cons p (string-append (%with-slash target) (%name p)))) paths))
        (list (cons (car paths) target)))))

(define (%act-replacing! act! path to)
  (guard (c [(i/o-file-already-exists-error? c)
             (and (ask:y-or-n? (format "Overwrite ~a? " (files:abbreviated-path to)))
                  (begin (act! path to (file-options no-fail)) #t))])
    (act! path to (file-options))
    #t))

(define (%resolved-folder path)
  (%with-slash (resolved-path (job-result 'dired:resolve %resolver (%parent-folder path)))))

(define (%mark-of path)
  (let* ([b (%listing-of (%parent-folder path))]
         [e (and b (find (lambda (e) (equal? (document:node-attribute e 'path) path)) (%entries b)))])
    (and e (document:node-attribute e 'mark))))

;; Each file lands at its resolved path, which the listings name, so its
;; mark is carried there and point follows it, as Dired moves point to
;; the file it made. Overwriting is asked only when files refuses the
;; target, so its refusals of the same file and of a file another buffer
;; visits come before the question.
(define (%operate! who verb paths target allowed? act! mark)
  (%check-paths who paths)
  (unless (string? target)
    (assertion-violation who "not a string" target))
  (let* ([pairs (%targets who paths target)] [landed '()] [carried (%no-carried-marks)]
         [summary (%for-each-path! verb paths
                    (lambda (path)
                      (let ([to (cdr (assoc path pairs))] [mark (or mark (%mark-of path))])
                        (and (allowed? path) (%act-replacing! act! path to)
                             (let ([at (string-append (%resolved-folder to) (%name to))])
                               (when mark (hashtable-set! carried at mark))
                               (set! landed (cons at landed))
                               #t)))))])
    (%refresh-folders! (append (map %parent-folder paths) (map %parent-folder landed)) carried)
    (let ([view (views:current)])
      (when (and view (pair? landed) (views:buffer view)
                 (equal? (folder (views:buffer view)) (%parent-folder (car landed))))
        (%point-on! view (car landed))))
    (ask:message summary)))

(commands:define-command (rename [paths (%current-paths 'dired:rename)] [target (%read-target 'dired:rename "Rename")])
  "Renames the one path of PATHS to TARGET, or moves each into the folder TARGET; buffers visiting them follow."
  (%operate! 'dired:rename "Moved" paths target (lambda (path) #t) files:rename-file #f))

(commands:define-command (copy [paths (%current-paths 'dired:copy)] [target (%read-target 'dired:copy "Copy")])
  "Copies the one path of PATHS to TARGET, or each into the folder TARGET; copies listed are marked C."
  (%operate! 'dired:copy "Copied" paths target
    (%recursion-allowed? (recursive-copies) "Recursive copies of ~a? " paths)
    files:copy-file #\C))

(commands:define-command (make-folder [path (ask:file-name "Create folder: " (files:directory))])
  "Makes the folder PATH and any missing folder above it, then puts point on the first folder made."
  (unless (string? path)
    (assertion-violation 'dired:make-folder "not a string" path))
  (let* ([path (%expand path)]
         [path (if (char=? (string-ref path (fx- (string-length path) 1)) #\/) (substring path 0 (fx- (string-length path) 1)) path)]
         [first (let loop ([p path])
                  (let ([parent (path-parent p)])
                    (if (or (string=? parent "") (string=? parent p) (file-exists? parent)) p (loop parent))))])
    (files:make-folder path)
    (let* ([parent (%resolved-folder first)] [made (string-append parent (path-last first))])
      (%refresh-folders! (list parent) (%no-carried-marks))
      (let ([view (views:current)] [b (%listing-of parent)])
        (when (and view b (eq? (views:buffer view) b))
          (%point-on! view made))))))

;; Dired's C-u w names the marked files from an inserted subfolder, which
;; a listing never holds, so C-u picks the paths as no prefix does.
(define (%names-to-copy)
  (let ([prefix (commands:prefix-argument)])
    (%current-paths 'dired:copy-names-as-kill (if (pair? prefix) #f prefix))))

(commands:define-command (copy-names-as-kill [paths (%names-to-copy)])
  "Pushes the names of PATHS, joined by spaces, onto the kill ring; with the prefix argument 0, their whole paths."
  (%check-paths 'dired:copy-names-as-kill paths)
  (let ([text (fold-left (lambda (s p) (if (string=? s "") p (string-append s " " p))) ""
                         (if (eqv? (commands:prefix-argument) 0) paths (map %name paths)))])
    (kill-ring:push! (list text))
    (ask:message text)))

(define (%read-sorting)
  (if (pair? (commands:prefix-argument))
      (string->symbol (ask:line "Sort by (name, time, size or extension): "))
      (if (eq? (buffers:with-buffer (buffers:current) (sort)) (sorting name)) (sorting time) (sorting name))))

(commands:define-command (sort-by [buffer (buffers:current)] [order (%read-sorting)])
  "Sets dired:sort to ORDER in the listing BUFFER and orders its entries again."
  (%check-listing 'dired:sort-by buffer)
  (unless ((%one-of (%sortings)) order)
    (assertion-violation 'dired:sort-by "not a dired:sorting name" order))
  (buffers:with-buffer buffer (options:set-local! sort order))
  (refresh buffer))

(commands:define-command (toggle-details [buffer (buffers:current)])
  "Shows or hides every column but marks and names in the listing BUFFER."
  (%check-listing 'dired:toggle-details buffer)
  (buffers:with-buffer buffer (options:set-local! hide-details? (not (hide-details?)))))

(define (size-text size)
  (unless (and (integer? size) (exact? size) (>= size 0))
    (assertion-violation 'dired:size-text "not a size" size))
  (number->string size))

(define %month-names '#("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

;; As ls: a time more than six months ago, or in the future, gives its
;; year in place of the hour.
(define %half-year 15778476)

(define (%two-digits n) (if (< n 10) (format "0~a" n) (number->string n)))

(define (time-text seconds)
  (unless (and (integer? seconds) (exact? seconds))
    (assertion-violation 'dired:time-text "not a time in seconds" seconds))
  (let* ([d (time-utc->date (make-time 'time-utc 0 seconds))]
         [now (time-second (current-time 'time-utc))]
         [day (date-day d)])
    (string-append (vector-ref %month-names (fx- (date-month d) 1))
                   (if (< day 10) "  " " ") (number->string day) " "
                   (if (and (<= seconds now) (> seconds (- now %half-year)))
                       (string-append (%two-digits (date-hour d)) ":" (%two-digits (date-minute d)))
                       (format "~5@a" (date-year d))))))

(define (%owner-text a) (or (file-attributes-owner a) (number->string (file-attributes-uid a))))

(define (%group-text a) (or (file-attributes-group a) (number->string (file-attributes-gid a))))

(define (%mode-text a)
  (let ([mode (file-attributes-mode a)] [type (file-attributes-type a)])
    (define (bit? b) (not (fx= 0 (fxand mode b))))
    (define (special x special-bit lower upper)
      (cond
        [(and (bit? special-bit) (bit? x)) lower]
        [(bit? special-bit) upper]
        [(bit? x) #\x]
        [else #\-]))
    (string (case type [(folder) #\d] [(link) #\l] [(file) #\-] [else #\?])
            (if (bit? #o400) #\r #\-) (if (bit? #o200) #\w #\-) (special #o100 #o4000 #\s #\S)
            (if (bit? #o40) #\r #\-) (if (bit? #o20) #\w #\-) (special #o10 #o2000 #\s #\S)
            (if (bit? #o4) #\r #\-) (if (bit? #o2) #\w #\-) (special #o1 #o1000 #\t #\T))))

(define (%column-text c a)
  (case c
    [(mode) (%mode-text a)]
    [(links) (number->string (file-attributes-links a))]
    [(owner) (%owner-text a)]
    [(group) (%group-text a)]
    [(size) (size-text (file-attributes-size a))]
    [(time) (time-text (file-attributes-modified a))]))

(define (%column-width c widths) (cdr (assq c widths)))

(define (%shown-columns) (if (hide-details?) '() (columns)))

(define (%draw-listing node view)
  (haml (:div.dired (views:draw-children view node))))

(define (%draw-folder node view)
  (let ([widths (document:node-attribute node 'widths)])
    (haml (:div.dired-folder
            ([style "--dired-columns:1ch "
                    (apply string-append (map (lambda (c) (format "~ach " (%column-width c widths))) (%shown-columns)))
                    "auto 1fr"])
            (views:draw-children view node)))))

(define (%sort-text)
  (string-append "by " (symbol->string (sort)) (if (reverse-sort?) ", reversed" "")
                 (if (folders-first?) ", folders first" "")))

(define (%draw-header node view)
  (let ([used (document:node-attribute node 'used)] [available (document:node-attribute node 'available)])
    (haml (:div.dired-header
            (:div ([data-face "dired.header"]) (views:draw-children view node))
            (:div.dired-summary
              (unless (hide-details?)
                (:span "total used in directory " (size-text used)))
              (when (and (not (hide-details?)) (free-space?) available)
                (:span " available " (size-text available)))
              (:span.dired-sort (%sort-text)))))))

(define (%name-face entry a)
  (case (document:node-attribute entry 'mark)
    [(#\D) "dired.flagged"]
    [(#f) (cond
            [(document:node-attribute entry 'broken) "dired.broken-link"]
            [(eq? (file-attributes-type a) (file-type link)) "dired.link"]
            [(eq? (file-attributes-type a) (file-type folder)) "dired.folder"]
            [else #f])]
    [else "dired.marked"]))

(define (%draw-entry node view)
  (let ([a (document:node-attribute node 'attributes)] [mark (document:node-attribute node 'mark)])
    (haml (:div.dired-entry ([data-mark (and mark (string mark))])
            (:div.dired-mark ([data-face "dired.mark"]) (if mark (string mark) " "))
            (map (lambda (c) (haml (:div ([class "dired-" (symbol->string c)]) (%column-text c a))))
                 (%shown-columns))
            (:div.dired-name ([data-keymap (views:keymap-mark name-keymap)] [data-face (%name-face node a)])
              (views:draw-children view node))
            (when (and (not (hide-details?)) (file-attributes-target a))
              (:div.dired-target "-> " (file-attributes-target a)))))))

(buffers:define-kind %listing (content nodes) (draw %draw-listing))
(buffers:define-kind %folder (content nodes) (draw %draw-folder))
(buffers:define-kind %header (stops none) (draw %draw-header))
(buffers:define-kind %entry (draw %draw-entry))
(ui:define-link %folder-link %follow-folder-link)

;; The header's links take typed text by their kind, so one read-only span
;; over the whole listing refuses every edit; the plugin writes with
;; reconcile! and splice!, which ask no layer.
(buffers:define-layer %read-only (read-only) (sticky both))

(define (%move-listing! b new-folder)
  (let* ([old (%listing-of new-folder)] [node (%folder-node (buffers:document b))]
         [datum (car (document:datums (document:slice (buffers:document b) (document:node-start node) (document:node-end node))))]
         [attributes (cadr datum)])
    (when old
      (for-each (lambda (view) (views:set-buffer! view b)) (views:showing old))
      (buffers:kill! old))
    (buffers:rename! b (files:abbreviated-path new-folder))
    (buffers:with-silent-edits b
      (buffers:reconcile! b (document:token (buffers:document b) 0)
        (list
          (apply %folder (map (lambda (a) (if (eq? (car a) 'path) (cons 'path new-folder) a)) attributes)
            (map (lambda (child)
                   (cond
                     [(not (pair? child)) child]
                     [(eq? (car child) %entry-kind)
                      (let ([name (cdr (assq 'key (cadr child)))])
                        (cons* (car child)
                               (map (lambda (a) (if (eq? (car a) 'path) (cons 'path (string-append new-folder name)) a))
                                    (cadr child))
                               (cddr child)))]
                     [else
                      (let ([a (cadr child)])
                        (%header-datum new-folder (cdr (assq 'used a)) (cdr (assq 'available a))))]))
                 (cddr datum))))))
    (%protect! b)
    (when old
      (spawn-task (lambda (restore) (when (buffers:live? b) (refresh b)))))))

(define (%follow-rename from to)
  (for-each
    (lambda (b)
      (let* ([listed (folder b)] [new (and listed (files:renamed-path listed from to))])
        (when new (%move-listing! b new))))
    (%listings))
  (%remember-folders!))

(define (%forget-killed b)
  (when (folder b)
    (saved:set! %folders (map folder (remq b (%listings))))))

;; A folder gone since the last run is left out, as Emacs's desktop
;; leaves out a missing folder.
(define (%reopen!)
  (for-each
    (lambda (f)
      (unless (%listing-of f)
        (guard (c [(and (i/o-error? c) (not (cancelled? c)))
                   (ask:message (format "Folder ~a no longer exists" (files:abbreviated-path f)))])
          (visit f))))
    (%folders))
  (%remember-folders!))

(define (%entry-target view)
  (let ([entry (entry-at view)])
    (and entry
         (let ([path (entry-path entry)])
           (completion:make-target completion:file-category path (files:abbreviated-path path)
                                   (document:node-start entry) (document:node-end entry))))))

(define (%set-local-options)
  (options:set-local! files:offer-save? #f buffers:revert-function refresh buffers:stale-function %stale?)
  (hooks:add-local! completion:target-finders %entry-target -20))

(hooks:add! mode-hook %set-local-options)
(hooks:add! files:folder-visitors visit)
(hooks:add! files:directory-finders folder)
(hooks:add! files:after-rename %follow-rename)
(hooks:add! buffers:killed %forget-killed)
(tables:set! web:stylesheets 'dired "dired/dired.css")
(on-unload stop-waiting!)
(keys:bind! keys:global "C-x d" open)
(keys:bind! keys:global "C-x C-j" jump)
(keys:bind! keymap "RET" find-file)
(keys:bind! keymap "f" find-file)
(keys:bind! keymap "e" find-file)
(keys:bind! keymap "o" find-file-other-view)
(keys:bind! keymap "C-o" display-file)
(keys:bind! keymap "^" up)
(keys:bind! keymap "n" next-line)
(keys:bind! keymap "SPC" next-line)
(keys:bind! keymap "p" previous-line)
(keys:bind! keymap "S-SPC" previous-line)
(keys:remap! keymap editing:next-line next-line)
(keys:remap! keymap editing:previous-line previous-line)
(keys:bind! keymap "m" mark)
(keys:bind! keymap "* m" mark)
(keys:bind! keymap "u" unmark)
(keys:bind! keymap "* u" unmark)
(keys:bind! keymap "DEL" unmark-backward)
(keys:bind! keymap "* DEL" unmark-backward)
(keys:bind! keymap "d" flag-deletion)
(keys:bind! keymap "U" unmark-all)
(keys:bind! keymap "* !" unmark-all)
(keys:bind! keymap "t" toggle-marks)
(keys:bind! keymap "* t" toggle-marks)
(keys:bind! keymap "* /" mark-folders)
(keys:bind! keymap "* @" mark-links)
(keys:bind! keymap "* *" mark-executables)
(keys:bind! keymap "x" delete-flagged)
(keys:bind! keymap "D" delete)
(keys:bind! keymap "R" rename)
(keys:bind! keymap "C" copy)
(keys:bind! keymap "+" make-folder)
(keys:bind! keymap "w" copy-names-as-kill)
(keys:bind! keymap "s" sort-by)
(keys:bind! keymap "(" toggle-details)
(keys:bind! name-keymap "<mouse-1>" mouse-find-file)
(keys:bind! name-keymap "<mouse-2>" mouse-find-file)
(keys:bind! name-keymap "<down-mouse-1>" keys:ignore)
(keys:bind! name-keymap "<drag-mouse-1>" keys:ignore)
(spawn-task (lambda (restore) (%reopen!)))
(for-each (lambda (command) (tables:set! commands:region-commands command #t))
          (list mark unmark flag-deletion toggle-marks))
