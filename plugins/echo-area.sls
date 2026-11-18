#!tuna
(import (buffers) (document) (views) (layout) (layout-sides) (keys) (commands) (faces) (web) (haml) (undo))

(define face
  (make-thread-parameter #f
    (lambda (v)
      (unless (or (not v) (symbol? v))
        (assertion-violation 'echo-area:face "not a face or #f" v))
      v)))

(define-option log-max 1000 (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "How many lines *Messages* keeps; the oldest go first.")

(define-table keymap "The echo area's keymap, for clicks on it.")

;; The plugin writes both buffers with splice!, which asks no kind, so
;; their kinds refuse every other edit.
(define (%refuse-edits node edit) #f)

(define (hidden?) #f)

;; Drawing nothing, rather than an empty line, lets the part take no room.
(define (%draw-area node view)
  (if (hidden?)
      '()
      (let ([f (document:node-attribute node 'face #f)])
        (haml (:div.echo-area-message ([role "status"] [data-face (and (symbol? f) (symbol->string f))])
                (views:draw-children view node))))))

(buffers:define-kind area (consent %refuse-edits) (keymap keymap) (draw %draw-area))

(buffers:define-kind %log (consent %refuse-edits))

(module %internals
  (check-main-thread echo-buffer messages-buffer shown? show! log! queue-report! flushing? flush-reports! report-text)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define echo-buffer
    (or (buffers:find " *Echo Area*") (buffers:make " *Echo Area*" (area '()))))

  (define shown? (fx> (document:length (buffers:document echo-buffer)) 2))

  ;; Set first, so a quit landing in the edit leaves a key to clear an
  ;; echo area that may show nothing, never a message no key clears.
  (define (show! text face)
    (set! shown? (or shown? (not (string=? text ""))))
    (buffers:splice! echo-buffer 0 (document:length (buffers:document echo-buffer))
      (document:from-datum (area (if face (list (cons 'face face)) '()) text)))
    (set! shown? (not (string=? text ""))))

  (define log-buffer #f)

  ;; A killed log is made again by whatever code logs next. Its setting
  ;; is this plugin's: code acting for no module cannot set it, and
  ;; another module's unload would take it back.
  (define (messages-buffer)
    (unless (and log-buffer (buffers:live? log-buffer))
      (as-module (this-module)
        (set! log-buffer (or (buffers:find "*Messages*") (buffers:make "*Messages*" (%log '()))))
        (buffers:with-buffer log-buffer (set-option-local! undo:limit 0))))
    log-buffer)

  (define (newlines text)
    (let loop ([i 0] [n 0])
      (if (fx= i (string-length text))
          n
          (loop (fx+ i 1) (if (char=? (string-ref text i) #\newline) (fx+ n 1) n)))))

  (define (times-logged entry text)
    (let ([n (string-length text)] [m (string-length entry)])
      (cond
        [(not (and (fx> m n) (string=? (substring entry 0 n) text))) 0]
        [(fx= m (fx+ n 1)) 1]
        [(and (fx>= m (fx+ n 11)) (string=? (substring entry n (fx+ n 2)) " [")
              (string=? (substring entry (fx- m 8) m) " times]\n"))
         (let ([count (string->number (substring entry (fx+ n 2) (fx- m 8)) 10)])
           (if (and (fixnum? count) (fx> count 1)) count 0))]
        [else 0])))

  ;; As Emacs does, a repeated message is found by reading the log's last
  ;; entry, so a count survives a reload of the plugin.
  (define (log! text)
    (let ([max (log-max)])
      (when (> max 0)
        (let* ([b (messages-buffer)] [doc (buffers:document b)] [end (fx- (document:length doc) 1)]
               [lines (fx- (document:line doc end) 1)] [k (fx+ (newlines text) 1)]
               [start (and (fx>= lines k) (document:line-start doc (fx+ (fx- lines k) 1)))]
               [times (if start (times-logged (document:text doc (fxmax start 1) end) text) 0)])
          (if (fx> times 0)
              (buffers:splice! b (fxmax start 1) end
                (document:from-datum (format "~a [~a times]\n" text (fx+ times 1))))
              (buffers:splice! b end end (document:from-datum (string-append text "\n"))))
          (let* ([doc (buffers:document b)] [end (fx- (document:length doc) 1)]
                 [lines (fx- (document:line doc end) 1)])
            (when (> lines max)
              (buffers:splice! b 1 (document:line-start doc (+ (- lines max) 1)) (document:from-datum ""))))))))

  ;; Report runs on whichever thread raised, so the queue is a box changed
  ;; only by compare-and-swap.
  (define reports (box '()))

  (define (queue-report! entry)
    (let loop ()
      (let ([old (unbox reports)])
        (unless (box-cas! reports old (cons entry old)) (loop)))))

  (define (take-reports!)
    (let loop ()
      (let ([old (unbox reports)])
        (if (box-cas! reports old '()) (reverse old) (loop)))))

  (define (put-back-reports! older)
    (unless (null? older)
      (let loop ()
        (let ([old (unbox reports)])
          (unless (box-cas! reports old (append old (reverse older))) (loop))))))

  ;; Reports raised while the queue shows wait for the next batch, so a
  ;; message that raises cannot show reports without end.
  (define flushing? #f)

  ;; A raise or a quit while the queue shows puts back the reports not
  ;; yet shown. The one showing is dropped, so a report whose showing
  ;; raises is not shown again without end. Reports are logged by the
  ;; setting, not by a binding where they were raised or where they show,
  ;; as Emacs logs a command's error once the command's bindings unwind.
  (define (flush-reports!)
    (unless (null? (unbox reports))
      (let ([left '()])
        (fluid-let ([flushing? #t])
          (dynamic-wind
            void
            (lambda ()
              (with-interrupts-disabled (set! left (take-reports!)))
              (let loop ()
                (unless (null? left)
                  (let ([entry (car left)])
                    (set! left (cdr left))
                    (with-options ([log-max (option-setting log-max)])
                      (parameterize ([face (cdr entry)])
                        (message! "~a" (car entry))))
                    (loop)))))
            (lambda ()
              (with-interrupts-disabled
                (put-back-reports! left)
                (set! left '()))))))))

  (define (message-text c)
    (let ([message (condition-message c)]
          [irritants (if (irritants-condition? c) (condition-irritants c) '())])
      (or (and (format-condition? c)
               (guard (e [(not (quit-condition? e)) #f]) (apply format message irritants)))
          (case (and (list? irritants) (length irritants))
            [(0) (format "~a" message)]
            [(1) (format "~a with irritant ~s" message (car irritants))]
            [else (format "~a with irritants ~s" message irritants)]))))

  (define (types-text c)
    (format "~{~a~^ ~}"
      (append
        (map (lambda (simple) (record-type-name (record-rtd simple)))
             (remp (lambda (simple)
                     (or (who-condition? simple) (irritants-condition? simple) (source-condition? simple)))
                   (simple-conditions c)))
        (if (irritants-condition? c)
            (list (format "with irritants ~s" (condition-irritants c)))
            '()))))

  ;; The same text as report's line after the module, less the source
  ;; form, which belongs to standard error rather than the user's screen.
  ;; A condition's irritants or a record's writer can raise.
  (define (report-text c)
    (guard (e [(not (quit-condition? e)) "condition that cannot be printed"])
      (cond
        [(not (condition? c)) (format "non-condition value ~s" c)]
        [else
         (string-append
           (if (who-condition? c) (format "~a: " (condition-who c)) "")
           (if (message-condition? c) (message-text c) (types-text c)))]))))

(import %internals)

(define (message! format-string . vs)
  (check-main-thread 'echo-area:message!)
  (unless (string? format-string)
    (assertion-violation 'echo-area:message! "not a string" format-string))
  (unless flushing? (flush-reports!))
  (let ([text (apply format format-string vs)])
    (show! text (face))
    (unless (string=? text "") (log! text))
    (void)))

(define (current-message)
  (check-main-thread 'echo-area:current-message)
  (and shown?
       (let ([doc (buffers:document echo-buffer)])
         (document:text doc 1 (fx- (document:length doc) 1)))))

(define (current-face)
  (check-main-thread 'echo-area:current-face)
  (and shown?
       (let ([f (document:node-attribute (document:token (buffers:document echo-buffer) 0) 'face #f)])
         (and (symbol? f) f))))

(commands:define-command (show-messages)
  "Shows *Messages* without selecting it, with point in its view at the end."
  (let* ([b (messages-buffer)] [v (layout:display-buffer b)])
    (views:set-point! v (fx- (document:length (buffers:document b)) 1))))

;; A quit is not reported: keyboard-quit's advice says it once.
(define (%queue-report report c)
  (report c)
  (unless (quit-condition? c)
    (queue-report! (cons (report-text c) (if (and (warning? c) (not (serious-condition? c))) faces:warning faces:error)))))

(define (%say-quit keyboard-quit)
  (keyboard-quit)
  (message! "Quit"))

;; Cleared before the key's command runs, so the command's own message
;; shows.
(define (%clear-on-key press client key)
  (when (and shown? (string? key))
    (show! "" #f))
  (press client key))

;; Report runs inside the code that raised, so the queue shows here,
;; before display draws, rather than in the middle of a failed edit or
;; draw. A raise here must not skip the advice it encloses.
(define (%show-reports ended)
  (guard (c [#t (report c)])
    (as-module (this-module) (flush-reports!)))
  (ended))

(define (%keep-echo-area b) (not (eq? b echo-buffer)))

;; Commands report before after-command, so a command's reports show as
;; it ends, ahead of every other entry, and an entry that reads the
;; message, as repeat's does, finds them shown.
(define (%show-command-reports command) (flush-reports!))

(messages-buffer)
(layout:display-buffer echo-buffer (layout-sides:display-at-side (layout:direction down) 90 'content '((locked . #t))))
(keys:bind! keymap "<mouse-1>" show-messages)
(keys:bind! keymap "<down-mouse-1>" keys:ignore)
(keys:bind! keys:global "C-h e" show-messages)
(table-set! web:stylesheets 'echo-area "echo-area/echo-area.css")
(add-hook! buffers:kill-queries %keep-echo-area)
(add-hook! commands:after-command %show-command-reports -100)
(advice-add! report %queue-report)
(advice-add! keys:keyboard-quit %say-quit)
(advice-add! keys:press! %clear-on-key)
(advice-add! batch-ended %show-reports)
(on-unload (lambda () (let ([v (layout:find-view echo-buffer)]) (when v (layout:delete-part! (layout:view-node v))))))
