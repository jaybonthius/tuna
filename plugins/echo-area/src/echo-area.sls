#!tuna
(import (buffers) (document) (views) (layout) (layout-split) (keys) (commands) (modes) (faces) (web) (haml) (ask) (hooks) (options) (tables) (timers))

(define %self (current-owner))

(define face
  (make-thread-parameter #f
    (lambda (v)
      (unless (or (not v) (symbol? v))
        (assertion-violation 'echo-area:face "not a face or #f" v))
      v)))

(define (%spans? v)
  (and (list? v)
       (for-all (lambda (s)
                  (and (list? s) (fx= (length s) 3) (fixnum? (car s)) (fixnum? (cadr s))
                       (fx<= 0 (car s) (cadr s)) (symbol? (caddr s))))
                v)))

(define spans
  (make-thread-parameter '()
    (lambda (v)
      (unless (%spans? v)
        (assertion-violation 'echo-area:spans "not a list of a start, an end and a face" v))
      v)))

;; Reports show through echo-area:message!, so its advice sees them, and
;; only the log takes the procedure's name before their text.
(define %log-prefix (make-thread-parameter ""))

(options:define-option log-max 1000 (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "How many lines *Messages* keeps; the oldest go first.")

(options:define-option echo-keystrokes 1 (lambda (v) (and (real? v) (finite? v) (not (negative? v))))
  "Seconds of pause after which the echo area shows a client's unfinished keys; 0 shows none.")

(options:define-option max-height 0.25
  (lambda (v) (or (and (flonum? v) (fl> v 0.0) (fl<= v 1.0)) (and (fixnum? v) (fx> v 0))))
  "How tall the echo area grows before its message scrolls: an inexact fraction of the page in (0, 1], or an exact count of lines.")

(tables:define-table keymap "The echo area's keymap, for clicks on it.")

;; The plugin writes both buffers with splice!, which asks no kind, so
;; their kinds refuse every other edit.
(define (%refuse-edits node edit) #f)

(define (hidden?) #f)

;; Drawing nothing, rather than an empty line, lets the part take no room.
(define (%draw-area node view)
  (if (hidden?)
      '()
      (let ([f (document:node-attribute node 'face #f)])
        (haml (:div.echo-area-message ([role "status"] [data-face (and (symbol? f) (symbol->string f))] [style (%max-height-style)])
                (views:draw-children view node))))))

(define (%max-height-style)
  (let ([v (max-height)])
    (string-append "--echo-area-max-height:"
      (if (fixnum? v) (string-append (number->string v) "lh") (string-append "calc(" (number->string v) " * 100dvh)")))))

(buffers:define-kind area (consent %refuse-edits) (keymap keymap) (draw %draw-area))

(buffers:define-kind %log (consent %refuse-edits))

(buffers:define-layer %message-faces)

(tables:define-table messages-keymap "Keys in *Messages*.")

(hooks:define-hook messages-mode-hook "Called in each buffer that turns on echo-area:messages-mode.")

(modes:define-major-mode messages-mode
  (parent modes:special)
  (lighter "Messages")
  (keymap messages-keymap)
  (hook messages-mode-hook)
  (plugin-only #t))

(module %internals
  (check-main-thread main-thread? echo-buffer messages-buffer shown? shown-spans show! log! queue-report! flushing? flush-reports! report-text
   make-queued-report print! end-printed!
   echo-text-prompt echo-text-keys echo-text-waiting? shown-echo uncover-echo! follow-key! follow-echoes! forget-echo!)

  (define main-thread (get-thread-id))

  (define (main-thread?) (fx= (get-thread-id) main-thread))

  (define (check-main-thread who)
    (unless (main-thread?)
      (assertion-violation who "not on the main thread")))

  (define echo-buffer
    (let ([b (or (buffers:find " *Echo Area*") (buffers:make " *Echo Area*" (area '())))])
      (buffers:with-buffer b (options:set-local! views:cursor-visible #f))
      b))

  (define shown? (fx> (document:length (buffers:document echo-buffer)) 2))

  (define shown-spans '())

  ;; Set first, so a cancel landing in the edit leaves a key to clear an
  ;; echo area that may show nothing, never a message no key clears.
  (define (show! text face ranges)
    (set! shown? (or shown? (not (string=? text ""))))
    (set! shown-spans '())
    (buffers:splice! echo-buffer 0 (document:length (buffers:document echo-buffer))
      (document:from-datum (area (if face (list (cons 'face face)) '()) text)))
    (let* ([n (string-length text)]
           [ranges (filter (lambda (r) (fx< (car r) (cadr r)))
                           (map (lambda (r) (list (fxmin (car r) n) (fxmin (cadr r) n) (caddr r))) ranges))])
      (buffers:set-spans! (buffers:layer echo-buffer %message-faces) 0 (document:length (buffers:document echo-buffer))
        (map (lambda (r) (list (fx+ (car r) 1) (fx+ (cadr r) 1) (list (cons 'face (caddr r))))) ranges))
      (set! shown-spans ranges))
    (set! shown? (not (string=? text "")))
    (when shown? (cover-echoes!)))

  (define-record-type echo-text
    (sealed #t)
    (fields prompt keys waiting? read?))

  (define-record-type echo
    (sealed #t)
    (fields client (mutable echoing?) (mutable timer) (mutable left) (mutable covered?) (mutable presses)))

  ;; Ephemeron, since each echo holds its client.
  (define echoes (make-ephemeron-eq-hashtable))

  (define (echo-for! client)
    (or (eq-hashtable-ref echoes client #f)
        (let ([e (make-echo client #f #f #f #f 0)])
          (eq-hashtable-set! echoes client e)
          e)))

  (define (cover-echoes!)
    (vector-for-each
      (lambda (e)
        (echo-covered?-set! e #t)
        (echo-left-set! e #f))
      (hashtable-values echoes)))

  ;; A read with a prompt shows the keys it has read after the prompt,
  ;; which stands in for the keys of the command reading.
  (define (keys-in-progress client prompt)
    (let ([parts (filter values (list (keys:prefix-description client)
                                      (and (not prompt) (keys:reading client))
                                      (keys:pending client)))])
      (and (pair? parts)
           (fold-left (lambda (text part) (string-append text " " part)) (car parts) (cdr parts)))))

  (define (in-progress? client)
    (and (or (keys:reading client) (keys:pending client) (keys:prefix-description client)) #t))

  ;; A temporary keymap's prompt shows only while the keymap is up, so a
  ;; key that ends the keymap leaves no copy of it, as a read's prompt
  ;; leaves its keys.
  (define (live-text e)
    (let* ([client (echo-client e)] [read-prompt (keys:reading-prompt client)] [prompt (keys:prompt client)]
           [keys (and (or prompt (echo-echoing? e)) (> (echo-keystrokes) 0) (keys-in-progress client read-prompt))])
      (and (or prompt keys) (make-echo-text prompt keys #t (and read-prompt #t)))))

  (define (shown-echo client)
    (let ([e (and client (eq-hashtable-ref echoes client #f))])
      (and e (not (and shown? (echo-covered? e))) (or (live-text e) (echo-left e)))))

  (define (uncover-echo! client)
    (echo-covered?-set! (echo-for! client) #f))

  (define (stop-timer! e)
    (when (echo-timer e)
      (timers:cancel! (echo-timer e))
      (echo-timer-set! e #f)))

  (define (start-timer! e)
    (call-as-owner %self
      (lambda ()
        (echo-timer-set! e
          (timers:run-after (echo-keystrokes)
            (lambda ()
              (echo-timer-set! e #f)
              (when (in-progress? (echo-client e))
                (echo-echoing?-set! e #t))))))))

  ;; Under a temporary keymap's prompt, a key that finishes no sequence of
  ;; its own is the keymap's to show, through the prompt.
  (define (finished-text before key)
    (let ([prompt (and (echo-text-read? before) (echo-text-prompt before))] [keys (echo-text-keys before)]
          [name (if (pair? key) (car key) key)])
      (and (or prompt keys (not (echo-text-prompt before)))
           (let ([keys (and (> (echo-keystrokes) 0) (if keys (string-append keys " " name) name))])
             (and (or prompt keys) (make-echo-text prompt keys #f (and prompt #t)))))))

  ;; The keys a key finishes are taken before it runs, since a finished
  ;; sequence leaves no pending keys to show them by, and its command may
  ;; pause. A key returns only when its command ends, maybe after other
  ;; keys of the client, so it settles the echo only if it is still the
  ;; client's latest; a key that returns at once with keys in progress
  ;; finished nothing.
  (define (follow-key! press client key)
    (let* ([e (echo-for! client)] [before (live-text e)] [n (fx+ (echo-presses e) 1)])
      (echo-presses-set! e n)
      (unless (echo-echoing? e) (stop-timer! e))
      (cond
        [before (echo-left-set! e (finished-text before key))]
        [(string? key) (echo-left-set! e #f)])
      (press client key)
      (when (fx= (echo-presses e) n)
        (if (in-progress? client)
            (echo-left-set! e #f)
            (echo-echoing?-set! e #f)))))

  ;; A read can start in a task a key resumed rather than in the key's
  ;; command, and keys can end without a key, so each batch's end
  ;; settles what the keys left.
  (define (follow-echoes!)
    (vector-for-each
      (lambda (e)
        (let ([client (echo-client e)])
          (cond
            [(not (in-progress? client))
             (echo-echoing?-set! e #f)
             (stop-timer! e)]
            [(not (or (echo-echoing? e) (echo-timer e) (keys:reading-prompt client) (zero? (echo-keystrokes))))
             (start-timer! e)])))
      (hashtable-values echoes)))

  (define (forget-echo! client)
    (let ([e (eq-hashtable-ref echoes client #f)])
      (when e
        (stop-timer! e)
        (eq-hashtable-delete! echoes client))))

  (define log-buffer #f)

  ;; The log holds nothing to save, so it never reads as modified, which
  ;; would make killing it ask.
  (define (messages-buffer)
    (unless (and log-buffer (buffers:live? log-buffer))
      (set! log-buffer (or (buffers:find "*Messages*") (buffers:make "*Messages*" (%log '()))))
      (buffers:set-silent! log-buffer #t)
      (unless (eq? (modes:major-mode log-buffer) messages-mode)
        (modes:set-major-mode messages-mode log-buffer)))
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

  (define (trim-log! b max)
    (let* ([doc (buffers:document b)] [end (fx- (document:length doc) 1)]
           [lines (fx- (document:line doc end) 1)])
      (when (> lines max)
        (buffers:splice! b 1 (document:line-start doc (+ (- lines max) 1)) (document:from-datum "")))))

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
          (trim-log! b max)))))

  (define printing? #f)

  ;; The log keeps a line break after an unended printed line all the
  ;; same, so a message never has to end it, and a write goes in before it.
  (define open-log #f)

  (define (print! text)
    (if printing?
        (let ([end (fx- (document:length (buffers:document echo-buffer)) 1)])
          (buffers:splice! echo-buffer end end (document:from-datum text)))
        (begin
          (show! text #f '())
          (set! printing? #t)))
    (let ([max (log-max)])
      (when (> max 0)
        (let* ([b (messages-buffer)] [end (fx- (document:length (buffers:document b)) 1)]
               [n (string-length text)] [ends-line? (char=? (string-ref text (fx- n 1)) #\newline)])
          (if (eq? open-log b)
              (let ([joined (if ends-line? (substring text 0 (fx- n 1)) text)])
                (unless (string=? joined "")
                  (buffers:splice! b (fx- end 1) (fx- end 1) (document:from-datum joined))))
              (buffers:splice! b end end (document:from-datum (if ends-line? text (string-append text "\n")))))
          (set! open-log (and (not ends-line?) b))
          (trim-log! b max)))))

  ;; An ended printed line counts as a repeat of the line before it, as a
  ;; message does, and Emacs checks for the repeat only when it ends the
  ;; line.
  (define (end-printed!)
    (set! printing? #f)
    (let ([b open-log])
      (set! open-log #f)
      (when (and b (buffers:live? b))
        (let* ([doc (buffers:document b)] [end (fx- (document:length doc) 1)]
               [lines (fx- (document:line doc end) 1)])
          (when (fx>= lines 2)
            (let* ([start (fxmax (document:line-start doc lines) 1)]
                   [before (fxmax (document:line-start doc (fx- lines 1)) 1)]
                   [text (document:text doc start (fx- end 1))]
                   [times (times-logged (document:text doc before start) text)])
              (when (fx> times 0)
                (buffers:splice! b before end
                  (document:from-datum (format "~a [~a times]\n" text (fx+ times 1)))))))))))

  ;; Report runs on whichever thread raised, so the queue is a box changed
  ;; only by compare-and-swap.
  (define reports (box '()))

  (define-record-type queued-report
    (sealed #t)
    (fields who text face))

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

  ;; A raise or a cancel while the queue shows puts back the reports not
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
              (call-with-cancellation-masked (lambda (restore) (set! left (take-reports!))))
              (let loop ()
                (unless (null? left)
                  (let ([entry (car left)])
                    (set! left (cdr left))
                    (options:with ([log-max (options:setting log-max)])
                      (parameterize ([face (queued-report-face entry)] [spans '()] [%log-prefix (queued-report-who entry)])
                        (message! "~a" (queued-report-text entry))))
                    (loop)))))
            (lambda ()
              (call-with-cancellation-masked
                (lambda (restore)
                  (put-back-reports! left)
                  (set! left '())))))))))

  (define (message-text c)
    (let ([message (condition-message c)]
          [irritants (if (irritants-condition? c) (condition-irritants c) '())])
      (or (and (format-condition? c)
               (guard (e [(not (cancelled? e)) #f]) (apply format message irritants)))
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
    (guard (e [(not (cancelled? e)) (values "" "condition that cannot be printed")])
      (cond
        [(not (condition? c)) (values "" (format "non-condition value ~s" c))]
        [else
         (values (if (who-condition? c) (format "~a: " (condition-who c)) "")
                 (if (message-condition? c) (message-text c) (types-text c)))]))))

(import %internals)

(define (message! format-string . vs)
  (check-main-thread 'echo-area:message!)
  (unless (string? format-string)
    (assertion-violation 'echo-area:message! "not a string" format-string))
  (unless flushing? (flush-reports!))
  (let ([text (apply format format-string vs)])
    (end-printed!)
    (show! text (face) (spans))
    (unless (string=? text "") (log! (string-append (%log-prefix) text)))
    (void)))

(define (%print text)
  (unless flushing? (flush-reports!))
  (print! text))

;; The port keeps no buffer, so its handler sees every write as it
;; happens, in order with messages and reports, and a write from another
;; thread never touches a buffer the main thread is writing. Only the main
;; thread counts and keeps the line state, since a count shared by threads
;; would lose writes. Chez keeps no line state for a generic port, so the
;; handler keeps it; otherwise fresh-line, which report calls on the
;; current output port, would log an empty line before every report.
(define (open-output-port)
  (let* ([count 0]
         [port (make-output-port
                 (lambda (message . args)
                   (case message
                     [(write-char)
                      (let ([c (car args)])
                        (if (main-thread?)
                            (begin
                              (set! count (+ count 1))
                              (set-port-bol! (cadr args) (char=? c #\newline))
                              (%print (string c)))
                            (put-char (console-output-port) c)))]
                     [(block-write)
                      (let ([n (caddr args)])
                        (when (fx> n 0)
                          (let ([text (substring (cadr args) 0 n)])
                            (if (main-thread?)
                                (begin
                                  (set! count (+ count n))
                                  (set-port-bol! (car args) (char=? (string-ref text (fx- n 1)) #\newline))
                                  (%print text))
                                (put-string (console-output-port) text)))))]
                     [(file-position)
                      (if (null? (cdr args))
                          count
                          (assertion-violation 'echo-area:open-output-port "the port cannot be positioned" (cadr args)))]
                     [(flush-output-port)
                      (unless (main-thread?) (flush-output-port (console-output-port)))]
                     [(clear-output-port) (void)]
                     [(close-port) (mark-port-closed! (car args))]
                     [(port-name) "echo area"]
                     [else (assertion-violation 'echo-area:open-output-port "not an operation of the port" message)]))
                 "")])
    (set-port-bol! port #t)
    port))

(define (current-message)
  (check-main-thread 'echo-area:current-message)
  (and shown?
       (let ([doc (buffers:document echo-buffer)])
         (document:text doc 1 (fx- (document:length doc) 1)))))

(define (current-spans)
  (check-main-thread 'echo-area:current-spans)
  (if shown? shown-spans '()))

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
  (unless (cancelled? c)
    (let-values ([(who text) (report-text c)])
      (queue-report! (make-queued-report who text (if (and (warning? c) (not (serious-condition? c))) faces:warning faces:error))))))

(define (%say-quit keyboard-quit)
  (keyboard-quit)
  (message! "Quit"))

;; Cleared before the key's command runs, so the command's own message
;; shows.
(define (%clear-on-key press client key)
  (when (string? key)
    (end-printed!)
    (when shown? (show! "" #f '())))
  (press client key))

(define (keys-text client)
  (check-main-thread 'echo-area:keys-text)
  (unless (web:client? client)
    (assertion-violation 'echo-area:keys-text "not a client" client))
  (let* ([text (shown-echo client)] [keys (and text (echo-text-keys text))])
    (and keys (if (echo-text-waiting? text) (string-append keys "-") keys))))

;; A view draws the same for every client, so a client's echo is drawn
;; here, where the client is known, in place of the echo area's view.
(define (%draw-client-echo draw-view-atom node view client)
  (let ([text (and view (eq? (views:buffer view) echo-buffer) (not (hidden?)) (shown-echo client))])
    (if text
        (let ([prompt (echo-text-prompt text)] [keys (keys-text client)])
          (list (haml (:div.echo-area-message ([role "status"] [data-keymap (views:keymap-mark keymap)] [style (%max-height-style)])
                        (:div.echo-area-echo
                          (when prompt (%prompt-html prompt))
                          (when keys keys))))))
        (draw-view-atom node view client))))

(define (%control-char? c)
  (let ([n (char->integer c)])
    (or (fx< n 32) (fx= n 127))))

;; Drawn as is, a control character in typed text would show as nothing
;; or break the line. The prompt part takes the same rule, since it can
;; hold typed text, as a replace's query; so a prompt cannot break its own
;; line.
(define (%control-split text)
  (let ([n (string-length text)])
    (let loop ([i 0] [from 0] [acc '()])
      (cond
        [(fx= i n) (reverse (if (fx< from n) (cons (substring text from n) acc) acc))]
        [(%control-char? (string-ref text i))
         (loop (fx+ i 1) (fx+ i 1)
               (cons (string-ref text i) (if (fx< from i) (cons (substring text from i) acc) acc)))]
        [else (loop (fx+ i 1) from acc)]))))

(define (%glyph-html c)
  (haml (:span ([data-face (symbol->string faces:escape-glyph)])
          (string #\^ (integer->char (fxlogxor (char->integer c) 64))))))

(define (%adjacent-strings-joined parts)
  (fold-right
    (lambda (part acc)
      (if (and (string? part) (pair? acc) (string? (car acc)))
          (cons (string-append part (car acc)) (cdr acc))
          (cons part acc)))
    '()
    parts))

;; A glyph ends the prompt's span rather than sitting in it, so it shows in
;; escape-glyph alone, not over the prompt's weight and font.
(define (%prompt-html prompt)
  (map (lambda (part)
         (if (string? part)
             (map (lambda (piece) (if (char? piece) (%glyph-html piece) (haml (:span.echo-area-prompt piece))))
                  (%control-split part))
             (let ([shown (map (lambda (piece) (if (char? piece) (%glyph-html piece) piece)) (%control-split (cdr part)))])
               (if (car part)
                   (haml (:span ([data-face (symbol->string (car part))]) shown))
                   shown))))
       (%adjacent-strings-joined (if (string? prompt) (list prompt) prompt))))

(define (%follow-key press client key) (follow-key! press client key))

;; A message covers every client's echo while it shows, but a temporary
;; keymap's prompt must show while the keymap waits for a key.
(define (%show-keymap-prompt push client keymap keep . rest)
  (when (and (fx= (length rest) 2) (cadr rest))
    (uncover-echo! client))
  (apply push client keymap keep rest))

(define (%forget-echo client) (forget-echo! client))

;; A message covers every client's echo while it shows, but a read's
;; prompt must show while it waits for a key.
(define (%show-prompt read . prompt)
  (let ([client (web:current-client)])
    (when (and client (pair? prompt) (car prompt))
      (uncover-echo! client)))
  (apply read prompt))

(define (%follow-echoes ended)
  (guard (c [#t (report c)])
    (follow-echoes!))
  (ended))

;; Report runs inside the code that raised, so the queue shows here,
;; before layout draws the clients, rather than in the middle of a failed edit or
;; draw. A raise here must not skip the advice it encloses.
(define (%show-reports ended)
  (guard (c [#t (report c)])
    (call-as-owner %self (lambda () (flush-reports!))))
  (ended))

(define (%keep-echo-area b) (not (eq? b echo-buffer)))

;; Commands report before after-command, so a command's reports show as
;; it ends, ahead of every other entry, and an entry that reads the
;; message, as repeat's does, finds them shown.
(define (%show-command-reports command) (flush-reports!))

(define (%follow-messages) (options:set-local! views:point-after-insertion? #t))

(hooks:add! messages-mode-hook %follow-messages)
(keys:bind! messages-keymap "g" keys:undefined)
(messages-buffer)
(layout:display-buffer echo-buffer (layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t))))
(keys:bind! keymap "<mouse-1>" show-messages)
(keys:bind! keymap "<down-mouse-1>" keys:ignore)
(keys:bind! keys:global "C-h e" show-messages)
(tables:set! web:stylesheets 'echo-area "echo-area/echo-area.css")
(options:set! ask:message-writer (lambda (text) (message! "~a" text)))
(hooks:add! buffers:kill-queries %keep-echo-area)
(hooks:add! commands:after-command %show-command-reports -100)
(advice-add! report %queue-report)
(advice-add! keys:keyboard-quit %say-quit)
(advice-add! keys:press! %clear-on-key)
(advice-add! keys:press! %follow-key)
(advice-add! keys:read-key %show-prompt)
(advice-add! keys:push-keymap! %show-keymap-prompt)
(advice-add! keys:read-key-sequence %show-prompt)
(advice-add! layout:draw-view-atom %draw-client-echo)
(advice-add! batch-ended %show-reports)
(advice-add! batch-ended %follow-echoes)
(hooks:add! web:client-removed %forget-echo)
(on-unload (lambda () (let ([v (layout:find-view echo-buffer)]) (when v (layout:delete-part! (layout:view-node v))))))
