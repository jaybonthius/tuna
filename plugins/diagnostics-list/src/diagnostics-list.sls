#!tuna
(import (diagnostics) (jump-history) (next-error) (pulse) (status-line) (ui) (projects) (files) (buffers) (document) (views)
        (layout) (editing) (modes) (commands) (keys) (faces) (haml) (hooks) (options) (tables))

(define-record-type %list
  (sealed #t)
  (fields target (mutable rows)))

(define %lists (make-weak-eq-hashtable))

(tables:define-table keymap "Keys in diagnostics lists.")

(tables:define-table link-keymap "Clicks on a row's message, and on a project list's file: a click goes to the row's diagnostic.")
(hooks:define-hook mode-hook "Called in each buffer that turns on diagnostics-list:mode.")

(modes:define-major-mode mode (parent modes:special) (lighter "Diagnostics") (keymap keymap) (hook mode-hook) (plugin-only #t))

(define (%list-node b) (document:token (buffers:document b) 0))

(define (%line-and-column d)
  (let ([b (diagnostics:diagnostic-buffer d)] [start (diagnostics:diagnostic-start d)])
    (if b
        (let* ([doc (buffers:document b)] [line (document:line doc start)] [chars (document:unit characters)])
          (cons line (fx- (document:offset doc start chars) (document:offset doc (document:line-start doc line) chars))))
        start)))

(define (%relative path root)
  (let ([n (string-length root)])
    (if (and (fx> (string-length path) n) (string=? (substring path 0 n) root)) (substring path n (string-length path)) path)))

(define (%face s)
  (symbol->string (case s [(error) faces:error] [(warning) faces:warning] [else faces:success])))

(define (%severity-label s)
  (haml (:span.ui-label ([data-face (%face s)]) (symbol->string s))))

(define (%link text)
  (haml (:span.ui-label ([data-keymap (views:keymap-mark link-keymap)]) text)))

(define (%draw-row target d)
  (let ([lc (%line-and-column d)] [origin (diagnostics:diagnostic-origin d)] [code (diagnostics:diagnostic-code d)])
    (apply ui:row
      (append
        (if (string? target)
            (list (%link (%relative (or (diagnostics:diagnostic-path d) "") target)))
            '())
        (list (ui:label (format "~a:~a" (car lc) (cdr lc)))
              (%severity-label (diagnostics:diagnostic-severity d)))
        (if (or origin code)
            (list (ui:label (string-append (or origin "") (if (and origin code) " " "") (or code ""))))
            '())
        (list (%link (diagnostics:diagnostic-message d)))))))

(define (%diagnostics-of target)
  (if (string? target) (diagnostics:under target) (diagnostics:in target)))

;; ui keeps each view's row index, which after a change names another
;; diagnostic, so each view's diagnostic is selected again by identity.
(define (%fill! b)
  (let* ([l (eq-hashtable-ref %lists b #f)] [target (%list-target l)] [node (%list-node b)]
         [old (%list-rows l)]
         [kept (map (lambda (v) (let ([i (ui:selected-row node v)]) (cons v (and i (fx< i (vector-length old)) (vector-ref old i)))))
                    (views:showing b))]
         [rows (list->vector (%diagnostics-of target))])
    (%list-rows-set! l rows)
    (ui:set-rows! b node (vector-length rows)
      (lambda (i) (%draw-row target (vector-ref rows i)))
      (lambda (i) (%go! (vector-ref rows i) #t)))
    (for-each
      (lambda (k)
        (let ([i (and (cdr k) (%index-of rows (cdr k)))])
          (when i (ui:select-row! (%list-node b) (car k) i))))
      kept)))

(define (%index-of rows d)
  (let loop ([i 0])
    (cond
      [(fx= i (vector-length rows)) #f]
      [(eq? (vector-ref rows i) d) i]
      [else (loop (fx+ i 1))])))

(define (%position-of d b)
  (let ([start (diagnostics:diagnostic-start d)])
    (if (pair? start)
        (let* ([doc (buffers:document b)] [chars (document:unit characters)]
               [line (fxmin (car start) (document:line doc (document:length doc)))]
               [line-start (document:line-start doc line)])
          (document:position doc (fxmin (fx+ (document:offset doc line-start chars) (cdr start))
                                        (document:offset doc (document:length doc) chars))
                             chars))
        start)))

;; jump-history:push! records in the selected view's history, so the
;; place is recorded once the view it was left in is selected.
(define (%go! d select?)
  (let* ([b (or (diagnostics:diagnostic-buffer d) (files:visit (diagnostics:diagnostic-path d)))]
         [before (map (lambda (v) (cons v (and (views:buffer v) (cons (views:buffer v) (views:point v))))) (layout:views))]
         [view (layout:display-buffer b layout:display-in-other-view)]
         [start (%position-of d b)])
    (when select?
      (layout:select! view)
      (let ([left (assq view before)])
        (when (and left (cdr left)) (jump-history:push! (cadr left) (cddr left)))))
    (views:set-point! view start)
    (let ([ranges (list (list start (%end-of d b start)))])
      ;; Showing a row's diagnostic is a step, not a jump, so it marks
      ;; without recentring, as Flymake's flymake-show-diagnostic does.
      (if select?
          (parameterize ([jump-history:place-ranges ranges])
            (jump-history:after-jump view))
          (pulse:highlight! view ranges)))))

;; A diagnostic of a file no buffer visited has no end in the buffer, so
;; its line's end serves, as Flymake's does.
(define (%end-of d b start)
  (let ([end (diagnostics:diagnostic-end d)] [doc (buffers:document b)])
    (if (and (fixnum? end) (diagnostics:diagnostic-buffer d) (fx< start end))
        end
        (let ([line (document:line doc start)])
          (if (fx< line (document:line doc (document:length doc)))
              (fx- (document:line-start doc (fx+ line 1)) 1)
              (document:length doc))))))

(define (%selected who)
  (let* ([view (views:current)] [b (views:buffer view)] [l (eq-hashtable-ref %lists b #f)]
         [i (and l (ui:selected-row (%list-node b) view))])
    (unless (and i (fx< i (vector-length (%list-rows l))))
      (error who "Nothing at point"))
    (vector-ref (%list-rows l) i)))

(commands:define-command (go-to-diagnostic)
  "Goes to the selected row's diagnostic in another view, recording the place that view leaves."
  (%go! (%selected 'diagnostics-list:go-to-diagnostic) #t))

(commands:define-command (show-diagnostic)
  "Shows the selected row's diagnostic in another view, staying in the list."
  (%go! (%selected 'diagnostics-list:show-diagnostic) #f))

(commands:define-command (mouse-go-to-diagnostic [event (keys:command-event)])
  "Goes to the diagnostic of the row clicked, as diagnostics-list:go-to-diagnostic does, after selecting the list's view and that row."
  (unless (keys:event? event)
    (assertion-violation 'diagnostics-list:mouse-go-to-diagnostic "not a mouse event" event))
  (let* ([posn (keys:event-end event)] [view (views:posn-view posn)] [p (views:posn-point posn)])
    (unless (and view p (eq-hashtable-ref %lists (views:buffer view) #f))
      (error 'diagnostics-list:mouse-go-to-diagnostic "Nothing at point"))
    (layout:select! view)
    (views:set-point! view p)
    (%go! (%selected 'diagnostics-list:mouse-go-to-diagnostic) #t)))

(commands:define-command (next-diagnostic [n (commands:prefix-number)])
  "Selects the row N after the selected one and shows its diagnostic."
  (ui:next-row n)
  (%go! (%selected 'diagnostics-list:next-diagnostic) #f)
  (next-error:tell-locus (views:buffer (views:current)) n))

(commands:define-command (previous-diagnostic [n (commands:prefix-number)])
  "Selects the row N before the selected one and shows its diagnostic."
  (ui:previous-row n)
  (%go! (%selected 'diagnostics-list:previous-diagnostic) #f)
  (next-error:tell-locus (views:buffer (views:current)) (fx- 0 n)))

(define (%list-buffer name target)
  (let ([found (exists (lambda (b) (and (equal? (%list-target (eq-hashtable-ref %lists b #f)) target) b))
                       (filter buffers:live? (vector->list (hashtable-keys %lists))))])
    (or found
        (let ([b (buffers:make (buffers:free-name name) (ui:list '((click . select))))])
          (eq-hashtable-set! %lists b (make-%list target (vector)))
          (modes:set-major-mode mode b)
          b))))

(define (%show-buffer-list! b point)
  (unless (buffers:with-buffer b (diagnostics:mode))
    (error 'diagnostics-list:show-buffer-diagnostics "Diagnostics are off in this buffer"))
  (let ([lb (%list-buffer (string-append "*Diagnostics " (buffers:name b) "*") b)])
    (%fill! lb)
    (let ([view (layout:display-buffer lb)] [at (diagnostics:in b point)] [rows (%list-rows (eq-hashtable-ref %lists lb #f))])
      (ui:select-row! (%list-node lb) view (or (and (pair? at) (%index-of rows (car at))) 0)))))

(commands:define-command (show-buffer-diagnostics)
  "Shows the current buffer's diagnostics in a list."
  (%show-buffer-list! (buffers:current) (views:point (views:current))))

(commands:define-command (show-project-diagnostics)
  "Shows the diagnostics of the current buffer's project in a list."
  (let ([project (projects:find (files:directory))])
    (unless project
      (error 'diagnostics-list:show-project-diagnostics "The buffer is in no project"))
    (let* ([root (projects:root project)] [lb (%list-buffer (string-append "*Diagnostics " root "*") root)])
      (%fill! lb)
      (layout:display-buffer lb))))

(commands:define-command (refresh)
  "Builds the current list again, keeping the selected row's diagnostic selected."
  (let ([b (buffers:current)])
    (unless (eq-hashtable-ref %lists b #f)
      (error 'diagnostics-list:refresh "Not a diagnostics list"))
    (%fill! b)))

;; A buffer being killed visits no file any more, so which project its
;; diagnostics were under is unknown, and every project's list is built
;; again.
(define (%follow-change where)
  (for-each
    (lambda (lb)
      (when (buffers:live? lb)
        (let ([target (%list-target (eq-hashtable-ref %lists lb #f))])
          (when (if (string? target)
                    (let ([path (if (string? where) where (files:path where))])
                      (or (and (not path) (buffers:buffer? where))
                          (and path (fx> (string-length path) (string-length target))
                               (string=? (substring path 0 (string-length target)) target))))
                    (eq? target where))
            (%fill! lb)))))
    (vector->list (hashtable-keys %lists))))

(define (show-counts view)
  (let ([b (views:buffer view)])
    (and b (diagnostics:mode)
         (let loop ([ds (diagnostics:in b)] [errors 0] [warnings 0] [infos 0])
           (if (null? ds)
               (haml (:span.diagnostics-list-counts
                       (:span ([data-face (%face 'error)] [data-count (number->string errors)]) (number->string errors))
                       " "
                       (:span ([data-face (%face 'warning)] [data-count (number->string warnings)]) (number->string warnings))
                       " "
                       (:span ([data-face (%face 'info)] [data-count (number->string infos)]) (number->string infos))
                       (cond
                         [(diagnostics:checking? b) " Wait"]
                         [(diagnostics:check-failed? b) " !"]
                         [else ""])))
               (case (diagnostics:diagnostic-severity (car ds))
                 [(error) (loop (cdr ds) (fx+ errors 1) warnings infos)]
                 [(warning) (loop (cdr ds) errors (fx+ warnings 1) infos)]
                 [else (loop (cdr ds) errors warnings (fx+ infos 1))]))))))

(tables:define-table %counts-keymap "Clicks on the diagnostics counts.")

(commands:define-command (%show-clicked-diagnostics [event (keys:command-event)])
  "Shows the diagnostics of the buffer whose status line was clicked."
  (let ([view (layout:part-view (views:posn-node (keys:event-end event)))])
    (%show-buffer-list! (views:buffer view) (views:point view))))

(status-line:define-segment counts (show show-counts) (keymap %counts-keymap))

(define (%set-local-options) (options:set-local! buffers:revert-function refresh))

(hooks:add! mode-hook %set-local-options)
(hooks:add! diagnostics:changed %follow-change)
(keys:bind! keymap "RET" go-to-diagnostic)
(keys:bind! keymap "SPC" show-diagnostic)
(keys:bind! keymap "C-o" show-diagnostic)
(keys:bind! keymap "n" next-diagnostic)
(keys:bind! keymap "p" previous-diagnostic)
(keys:bind! keymap "<mouse-2>" editing:mouse-set-point)
(keys:bind! link-keymap "<mouse-1>" mouse-go-to-diagnostic)
(keys:bind! link-keymap "<mouse-2>" mouse-go-to-diagnostic)
(keys:bind! %counts-keymap "<mouse-1>" %show-clicked-diagnostics)
(tables:set! status-line:segments counts (status-line:right 40))
