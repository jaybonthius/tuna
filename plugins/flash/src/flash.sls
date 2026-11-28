#!tuna
(import (search) (buffers) (document) (views) (layout) (keys) (commands) (jump-history) (web) (ask) (faces) (options)
        (tables))

(define %self (current-owner))

;; A label is typed, so it is a character <printing-char> binds.
(define (%labels? v)
  (and (string? v)
       (let loop ([cs (string->list v)] [seen '()])
         (or (null? cs)
             (and (keys:printing-char? (car cs)) (not (memv (car cs) seen)) (loop (cdr cs) (cons (car cs) seen)))))))

(options:define-option labels "asdfjkl;ghqwertyuiopzxcvbnm" %labels?
  "The label characters, first given first: printing characters, none twice.")

(options:define-option all-views #t boolean?
  "Whether a jump covers every view its client shows, rather than the selected view only.")

(options:define-option dim #t boolean?
  "Whether a jump dims the text of its views other than the matches, with the face flash:backdrop.")

(options:define-option autojump #f boolean?
  "Whether a jump ends by itself when one match is left after a character is typed.")

(options:define-option rainbow #f boolean?
  "Whether labels take six colours in turn, in label order.")

(options:define-option style search:literal search:style?
  "The search style of flash:read-match's default query, read when a jump starts.")

(define backdrop 'flash.backdrop)

(tables:define-table keymap "The keymap of a jump, a temporary keymap of its client.")

(define-record-type (%target make-target target?)
  (sealed #t)
  (fields (immutable view target-view) (immutable start target-start) (immutable end target-end))
  (protocol
    (lambda (new)
      (lambda (view start end)
        (unless (views:view? view)
          (assertion-violation 'flash:make-target "not a view" view))
        (let ([b (views:buffer view)])
          (unless (and b (fixnum? start) (fixnum? end) (fx<= 0 start end (document:length (buffers:document b))))
            (assertion-violation 'flash:make-target "not a range of the view's buffer" view start end)))
        (new view start end)))))

(define-record-type %area
  (sealed #t)
  (fields view start end targets))

;; The resume is held only while the jump's task waits for a key, so a
;; command that finds none hands nothing to a task that is not waiting.
(define-record-type %jump
  (sealed #t)
  (fields client task query given views (mutable areas) (mutable pattern) (mutable error) (mutable labelled)
          (mutable drawn) (mutable sources) (mutable end-keymap) (mutable resume) (mutable ended?) (mutable outcome)))

(define %jumps (make-weak-eq-hashtable))

(define %cancelled (string->uninterned-symbol "cancelled"))

(define %last-pattern "")

(define (%current who)
  (or (eq-hashtable-ref %jumps (web:current-client) #f)
      (assertion-violation who "no jump runs for this client")))

;;; Finding targets

(define (%open? v)
  (let ([node (layout:view-node v)])
    (and node (views:buffer v) (not (layout:locked? node)))))

(define (%views)
  (let ([selected (layout:selected-view)])
    (if (all-views)
        (let ([others (filter (lambda (v) (and (not (eq? v selected)) (%open? v))) (layout:views))])
          (if (and selected (%open? selected)) (cons selected others) others))
        (if (and selected (%open? selected)) (list selected) '()))))

;; Where lines do not wrap, a match left or right of the columns the
;; client shows is not on screen.
(define (%column-filter v client)
  (let-values ([(columns rows) (views:body-size v client)]
               [(column line) (views:hscroll v client)])
    (if (and columns (not (views:with-view v (views:wrap-lines))))
        (let* ([doc (buffers:document (views:buffer v))] [width (views:with-view v (views:tab-width))])
          (lambda (start) (fx<= column (document:column doc start width) (fx+ column columns -1))))
        (lambda (start) #t))))

(define (%filter v client)
  (let ([on-screen? (%column-filter v client)])
    (lambda (buffer start end)
      (and (null? (views:folds-at v start)) (buffers:stop buffer start) (on-screen? start)))))

(define (%query-for j text)
  (let ([base (%jump-query j)])
    (search:query-with-partial
      (search:make-query text (search:query-style base) (search:query-case base) (search:query-spaces base)
                         (search:query-filter base)))))

(define (%matches v query start end)
  (let ([b (views:buffer v)])
    (let loop ([from start] [acc '()])
      (let ([m (and (fx<= from end) (search:find b query from (search:direction forward) start end))])
        (if m
            (loop (if (fx= (search:match-start m) (search:match-end m)) (fx+ (search:match-end m) 1) (search:match-end m))
                  (cons (make-target v (search:match-start m) (search:match-end m)) acc))
            (reverse acc))))))

(define (%search! j)
  (let ([client (%jump-client j)] [text (%jump-pattern j)])
    (%jump-error-set! j #f)
    (%jump-areas-set! j
      (fold-right
        (lambda (v acc)
          (let-values ([(shown-start shown-end) (views:shown-range v client)])
            (if shown-start
                (let-values ([(lo hi) (views:bounds v)])
                  (let ([start (fxmax lo shown-start)] [end (fxmin hi shown-end)])
                    (cons (make-%area v start end
                            (cond
                              [(%jump-given j)
                               (filter (lambda (t) (and (eq? (target-view t) v) (fx<= start (target-start t) end)))
                                       (%jump-given j))]
                              [(string=? text "") '()]
                              [else
                               (guard (c [(search:pattern-error? c) (%jump-error-set! j (search:pattern-error-description c text)) '()])
                                 (%matches v (search:query-with-filter (%query-for j text) (%filter v client)) start end))]))
                          acc)))
                acc)))
        '() (%jump-views j)))
    (%label! j)))

;;; Labels

(define (%ordered j)
  (let* ([areas (%jump-areas j)] [selected (layout:selected-view)]
         [point (and selected (views:buffer selected) (views:point selected))]
         [at-point? (lambda (t) (and (eq? (target-view t) selected) (fx= (target-start t) point)))]
         [all (apply append
                (map (lambda (a)
                       (if (eq? (%area-view a) selected)
                           (list-sort (lambda (x y)
                                        (let ([dx (fxabs (fx- (target-start x) point))] [dy (fxabs (fx- (target-start y) point))])
                                          (or (fx< dx dy) (and (fx= dx dy) (fx< (target-start x) (target-start y))))))
                                      (%area-targets a))
                           (%area-targets a)))
                     areas))])
    (append (remp at-point? all) (filter at-point? all))))

;; A label is no character that follows a match, as the query's case rule
;; compares them, so typing it could not continue the pattern.
(define (%allowed j)
  (let* ([text (%jump-pattern j)]
         [followers
          (apply append
            (map (lambda (a)
                   (let* ([b (views:buffer (%area-view a))] [doc (buffers:document b)]
                          [caseless? (and (not (string=? text ""))
                                          (guard (c [(search:pattern-error? c) #f])
                                            (search:query-caseless? (%query-for j text) b)))])
                     (fold-right
                       (lambda (t acc)
                         (let ([e (target-end t)])
                           (if (fx< e (document:length doc))
                               (let ([c (document:token doc e)])
                                 (if (char? c) (cons (cons c caseless?) acc) acc))
                               acc)))
                       '() (%area-targets a))))
                 (if (%jump-given j) '() (%jump-areas j))))])
    (filter (lambda (label)
              (not (exists (lambda (f)
                             (if (cdr f) (char=? (char-downcase label) (char-downcase (car f))) (char=? label (car f))))
                           followers)))
            (string->list (labels)))))

(define (%same-place? a b)
  (and (eq? (target-view a) (target-view b)) (fx= (target-start a) (target-start b))))

(define (%label! j)
  (let* ([ordered (%ordered j)] [allowed (%allowed j)] [before (%jump-labelled j)]
         [kept (fold-left
                 (lambda (acc t)
                   (let ([old (find (lambda (e) (%same-place? (car e) t)) before)])
                     (if (and old (memv (cdr old) allowed) (not (exists (lambda (e) (char=? (cdr e) (cdr old))) acc)))
                         (cons (cons t (cdr old)) acc)
                         acc)))
                 '() ordered)]
         [free (filter (lambda (c) (not (exists (lambda (e) (char=? (cdr e) c)) kept))) allowed)])
    (%jump-labelled-set! j
      (let loop ([ts ordered] [free free] [acc '()])
        (cond
          [(null? ts) (reverse acc)]
          [(find (lambda (e) (eq? (car e) (car ts))) kept) => (lambda (e) (loop (cdr ts) free (cons e acc)))]
          [(null? free) (loop (cdr ts) free acc)]
          [else (loop (cdr ts) (cdr free) (cons (cons (car ts) (car free)) acc))])))))

(define (%targets j) (apply append (map %area-targets (%jump-areas j))))

(define (%first-target j)
  (let ([ordered (%ordered j)])
    (and (pair? ordered) (car ordered))))

(define (%labelled-with j c)
  (let ([e (find (lambda (e) (char=? (cdr e) c)) (%jump-labelled j))])
    (and e (car e))))

;;; Drawing

(define (%css-string text)
  (call-with-string-output-port
    (lambda (out)
      (put-char out #\")
      (string-for-each (lambda (c) (when (memv c '(#\" #\\)) (put-char out #\\)) (put-char out c)) text)
      (put-char out #\"))))

(define (%label-attributes label)
  (list (cons "data-flash-label" label) (cons "style" (string-append "--flash-label: " (%css-string label)))))

(define (%rainbow-attributes n)
  (list (cons "data-flash-rainbow" n)))

(define-record-type %drawn
  (sealed #t)
  (fields view labels matches dimmed))

;; Made in the jump's task, where options bound around the call hold;
;; views only reads them.
(define (%drawing j)
  (let ([rainbow? (rainbow)] [dim? (dim)])
    (map (lambda (a)
           (let* ([v (%area-view a)] [n (document:length (buffers:document (views:buffer v)))]
                  [ranges (map (lambda (t) (cons (target-start t) (target-end t)))
                               (filter (lambda (t) (fx< (target-start t) (target-end t))) (%area-targets a)))])
             (make-%drawn v
               (let loop ([es (%jump-labelled j)] [i 0] [acc '()])
                 (cond
                   [(null? es) (reverse acc)]
                   [(and (eq? (target-view (caar es)) v) (fx< (target-start (caar es)) n))
                    (let ([s (target-start (caar es))] [label (list (cons 'flash-label (string (cdar es))))])
                      (loop (cdr es) (fx+ i 1)
                            (cons (list s (fx+ s 1)
                                        (if rainbow? (append label (list (cons 'flash-rainbow (fx+ 1 (fxmod i 6))))) label))
                                  acc)))]
                   [else (loop (cdr es) (fx+ i 1) acc)]))
               (map (lambda (r) (list (car r) (cdr r) (list (cons 'face faces:match.other)))) ranges)
               (and dim? ranges))))
         (%jump-areas j))))

(define (%backdrop-spans ranges start end)
  (let loop ([at start] [ranges (list-sort (lambda (x y) (fx< (car x) (car y))) ranges)] [acc '()])
    (cond
      [(null? ranges) (reverse (if (fx< at end) (cons (list at end (list (cons 'face backdrop))) acc) acc))]
      [else (loop (fxmax at (cdar ranges)) (cdr ranges)
                  (if (fx< at (caar ranges)) (cons (list at (caar ranges) (list (cons 'face backdrop))) acc) acc))])))

;; The labels' source ranks below the backdrop's, so no span's opacity
;; reaches a label; the matches' ranks above every other, so their
;; colours win inside the region too.
(define (%make-sources! j)
  (let ([client (%jump-client j)])
    (define (source spans-of)
      (lambda (v c start end)
        (let ([d (and (eq? c client) (find (lambda (d) (eq? (%drawn-view d) v)) (%jump-drawn j)))])
          (if d
              (filter (lambda (s) (and (fx< (car s) end) (fx< start (cadr s)))) (spans-of d start end))
              '()))))
    (%jump-sources-set! j
      (list (cons (source (lambda (d start end) (%drawn-labels d))) (most-negative-fixnum))
            (cons (source (lambda (d start end) (let ([r (%drawn-dimmed d)]) (if r (%backdrop-spans r start end) '()))))
                  (fx+ (most-negative-fixnum) 1))
            (cons (source (lambda (d start end) (%drawn-matches d))) (most-positive-fixnum))))
    (call-as-owner %self
      (lambda ()
        (for-each (lambda (s) (tables:set! views:span-sources (car s) (cdr s))) (%jump-sources j))))))

(define (%redraw! j) (%jump-drawn-set! j (%drawing j)))

(define (%remove-sources! j)
  (call-as-owner %self
    (lambda ()
      (for-each (lambda (s) (tables:remove! views:span-sources (car s))) (%jump-sources j)))))

(define (%prompt j)
  (let ([text (%jump-pattern j)])
    (if (and (string=? text "") (not (%jump-error j)))
        "Flash: "
        (string-append "Flash [" text "] (" (number->string (length (%targets j))) ")"
                       (if (%jump-error j) (string-append " [" (%jump-error j) "]") "")
                       ": "))))

;;; Running a jump

;; The one way a jump ends, in whichever task ends it. Its marks and
;; keymap go at once, so the screen drawn after the key that ended it
;; shows none; a task waiting for a key is resumed, or for a cancel
;; cancelled. Ending the keymap runs its on-exit, which finds the jump
;; ended.
(define (%end! j outcome)
  (unless (%jump-ended? j)
    (%jump-ended?-set! j #t)
    (%jump-outcome-set! j outcome)
    (when (and (target? outcome) (not (%jump-given j)))
      (set! %last-pattern (%jump-pattern j)))
    (let ([resume (%jump-resume j)] [client (%jump-client j)])
      (%jump-resume-set! j #f)
      (when (eq? (eq-hashtable-ref %jumps client #f) j)
        (eq-hashtable-delete! %jumps client))
      ;; Flash's unload takes its sources back itself, and refuses a
      ;; removal once it has begun.
      (when (and (%jump-sources j) (owner-live? %self)) (%remove-sources! j))
      (let ([end-keymap (%jump-end-keymap j)]) (when end-keymap (end-keymap)))
      (when resume
        (if (eq? outcome %cancelled)
            (cancel-task (%jump-task j))
            (resume (lambda () #f)))))))

(define (%hand! j key)
  (let ([resume (%jump-resume j)])
    (when resume
      (%jump-resume-set! j #f)
      (resume (lambda () key)))))

(define (%wait j)
  (web:suspend-for-input
    (lambda (resume)
      (if (%jump-ended? j)
          (resume (lambda () #f))
          (%jump-resume-set! j resume)))))

(define (%step! j key)
  (cond
    [(char? key)
     (let ([target (%labelled-with j key)])
       (cond
         [target (%end! j target)]
         [else
          (%set-pattern! j (string-append (%jump-pattern j) (string key)))
          (when (and (autojump) (fx= 1 (length (%targets j))))
            (%end! j (car (%targets j))))]))]
    [(eq? key 'delete)
     (let ([text (%jump-pattern j)])
       (unless (string=? text "")
         (%set-pattern! j (substring text 0 (fx- (string-length text) 1)))))]
    [(eq? key 'pick) (%end! j (%first-target j))]
    [(eq? key 'last)
     (when (and (not (%jump-given j)) (string=? (%jump-pattern j) "") (not (string=? %last-pattern "")))
       (%set-pattern! j %last-pattern))]))

(define (%set-pattern! j text)
  (%jump-pattern-set! j text)
  (%search! j))

(define (%keep found command)
  (and (memq command (list type delete-char pick-first insert-last-pattern cancel)) #t))

(define (%run client query given)
  (let ([j (make-%jump client (current-task) query given (%views) '() (search:query-text query) #f '() '() #f #f #f #f #f)])
    (eq-hashtable-set! %jumps client j)
    ;; A stop passes every handler, so a winder ends the jump; it also
    ;; runs each time the loop switches the waiting task out, which ends
    ;; nothing.
    (dynamic-wind
      void
      (lambda ()
        (%make-sources! j)
        (%jump-end-keymap-set! j (keys:push-keymap! client keymap %keep (lambda () (%end! j #f)) (lambda () (%prompt j))))
        (%search! j)
        (%redraw! j)
        (let loop ()
          (unless (%jump-ended? j)
            (let ([key (%wait j)])
              (unless (%jump-ended? j)
                (%step! j key)
                (%redraw! j)))
            (loop)))
        (let ([outcome (%jump-outcome j)])
          (if (eq? outcome %cancelled)
              (raise (make-cancelled #f))
              outcome)))
      (lambda ()
        (unless (memq (task-state (%jump-task j)) '(paused woken))
          (%end! j #f))))))

;; The jump runs as flash, so its keymap and marks are flash's and go
;; when flash unloads, and its task is then inside flash's code.
(define (%start who query given)
  (let ([client (web:current-client)])
    (unless client
      (assertion-violation who "no client's key ran the running command"))
    (when (eq-hashtable-ref %jumps client #f)
      (assertion-violation who "a jump is already running for this client"))
    (call-as-owner %self (lambda () (%run client query given)))))

(define read-match
  (case-lambda
    [() (read-match (search:make-query "" (style)))]
    [(query)
     (unless (search:query? query)
       (assertion-violation 'flash:read-match "not a query" query))
     (%start 'flash:read-match query #f)]))

(define (read-target targets)
  (unless (and (list? targets) (for-all target? targets))
    (assertion-violation 'flash:read-target "not a list of targets" targets))
  (%start 'flash:read-target (search:make-query "") targets))

(define (go-to target)
  (unless (target? target)
    (assertion-violation 'flash:go-to "not a target" target))
  (let ([view (target-view target)] [selected (layout:selected-view)])
    (unless (and (eq? view selected) (fx= (views:point selected) (target-start target)))
      (jump-history:push! (views:buffer selected) (views:point selected) selected))
    (layout:select! view)
    (views:set-point! view (target-start target))))

(commands:define-command (jump [prefix (commands:prefix-argument)])
  "Reads a target with flash:read-match and moves to it with flash:go-to; with a prefix argument, the jump flips flash:all-views."
  (let ([target (if prefix
                    (options:with ([all-views (not (all-views))]) (read-match))
                    (read-match))])
    (when target (go-to target))))

;;; Keys during a jump

(commands:define-command (type)
  "Hands the jump the typed character: a label shown ends the jump at its target; any other character joins the pattern."
  (let ([j (%current 'flash:type)] [c (keys:typed-char)])
    (unless c (assertion-violation 'flash:type "no character was typed"))
    (when (and (%jump-given j) (not (%labelled-with j c)))
      (error 'flash:type (string-append "No target labelled " (string c))))
    (%hand! j c)))

(commands:define-command (delete-char)
  "Removes the pattern's last character and searches again."
  (%hand! (%current 'flash:delete-char) 'delete))

(commands:define-command (pick-first)
  "Ends the jump at the target labelled first, the nearest; with no target, ends it with none."
  (%hand! (%current 'flash:pick-first) 'pick))

(commands:define-command (insert-last-pattern)
  "With an empty pattern, makes the pattern the one the last jump that reached a target ended with."
  (%hand! (%current 'flash:insert-last-pattern) 'last))

(commands:define-command (cancel)
  "Ends the jump and quits the command that started it."
  (%end! (%current 'flash:cancel) %cancelled)
  (ask:message "Quit"))

(keys:bind! keymap "<printing-char>" type)
(keys:bind! keymap "SPC" type)
(keys:bind! keymap "DEL" delete-char)
(keys:bind! keymap "RET" pick-first)
(keys:remap! keymap jump insert-last-pattern)
(keys:remap! keymap keys:keyboard-quit cancel)
(for-each (lambda (command) (tables:set! commands:command-modes command '()))
          (list type delete-char pick-first insert-last-pattern cancel))
(tables:set! views:span-properties 'flash-label %label-attributes)
(tables:set! views:span-properties 'flash-rainbow %rainbow-attributes)
(tables:set! web:stylesheets 'flash "flash/flash.css")
