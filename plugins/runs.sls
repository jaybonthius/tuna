#!tuna
(import (processes) (buffers) (document) (views) (modes) (keys) (commands) (faces) (ask) (files)
        (ansi-colors))

(define-option shell
  (list (let ([s (getenv "SHELL")]) (if (and s (fx> (string-length s) 0)) s "/bin/sh")) "-c")
  (lambda (v) (and (list? v) (pair? v) (for-all string? v)))
  "The shell's program and its switches, which a command line follows as the last argument.")

(define-option environment '(("TERM" . "dumb") ("PAGER" . "")) processes:environment?
  "Variables a run's program gets over Tuna's environment: names and values, where #f removes a variable.")

(define-option colors? #t boolean?
  "Whether SGR sequences style a run's output; with #f they are removed and the text stays plain.")

(define-option follow-output? #f boolean?
  "Whether a run starts with its views' points at the end of its buffer, so they follow its output.")

(define-option always-stop? #f boolean?
  "Whether runs:start stops the going run in its buffer without asking.")

(define-hook started
  "Called with a run's buffer once its header is written and its program is starting.")

(define-hook output-written
  "Called with a run's buffer and the start and end of the text written, after each piece of output, with the buffer current.")

(define-hook ended
  "Called once per run with its buffer and its end: 0, stopped, an exit code, -n for signal n, or the condition that kept the program from starting.")

(define-table keymap "Keys in a run's buffer.")

(define-hook mode-hook
  "Called in each buffer that turns on runs:mode or a mode derived from it.")

(modes:define-major-mode mode (parent modes:special) (lighter "Run") (keymap keymap) (hook mode-hook))

(define (%refuse-edits node edit) #f)

(buffers:define-kind %output (consent %refuse-edits))

(buffers:define-layer %styles (priority 0))

(define %output-kind (buffers:kind-name (buffers:constructor-kind %output)))

(define (%saved-runs? v)
  (or (null? v)
      (and (list? v) (fx>= (length v) 2) (fixnum? (car v)) (fixnum? (cadr v))
           (for-all (lambda (entry) (and (list? entry) (fx= (length entry) 12))) (cddr v)))))

;; Unload actions also run at exit, so the process id tells a reload,
;; whose user processes still run, from a restart, which has none.
(define-saved %saved-runs '() %saved-runs?)

(module %internals
  (check-main-thread check-command start-folder check-run-buffer run-of start-run! stop-run! run-command quoted-line run-mode
   run-directory run-environment run-end run-killed? own-runs going? save-runs! restore-runs!
   forget-killed! end-words)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define (check-command who command)
    (unless (cond
              [(string? command) (fx> (string-length command) 0)]
              [(list? command) (and (pair? command) (for-all string? command))]
              [else #f])
      (assertion-violation who "not a non-empty command line or list of strings" command)))

  (define-record-type run
    (sealed #t)
    (fields number (mutable process) command mode owner directory environment started
            (mutable offset) (mutable end) (mutable ended-at) (mutable line-start) (mutable cr?)
            (mutable filter) (mutable stretches) (mutable killed?)))

  (define runs (make-weak-eq-hashtable))

  (define last-number 0)

  (define (run-of b) (eq-hashtable-ref runs b #f))

  (define (check-run-buffer who b)
    (unless (buffers:buffer? b)
      (assertion-violation who "not a buffer" b))
    (or (run-of b) (assertion-violation who "the buffer shows no run" b)))

  (define (going? r) (not (run-end r)))

  (define (buffer-number b)
    (let ([doc (buffers:document b)])
      (and (fx> (document:length doc) 1)
           (let ([root (document:token doc 0)])
             (and (document:node? root) (eq? (document:node-kind root) %output-kind)
                  (document:node-attribute root 'run #f))))))

  (define (now) (let ([t (current-time 'time-utc)]) (+ (time-second t) (/ (time-nanosecond t) 1e9))))

  (define (time-text seconds)
    (let ([d (time-utc->date (make-time 'time-utc 0 (exact (floor seconds))))])
      (format "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d"
        (date-year d) (date-month d) (date-day d) (date-hour d) (date-minute d) (date-second d))))

  (define (quoted-line command)
    (if (string? command)
        command
        (fold-left (lambda (line word) (string-append line " " (shell-quote-argument word)))
                   (shell-quote-argument (car command)) (cdr command))))

  (define (header r)
    (format "Run started at ~a in ~a\n\n~a\n" (time-text (run-started r))
            (files:abbreviated-path (run-directory r)) (quoted-line (run-command r))))

  (define (end-words end)
    (cond
      [(eqv? end 0) "finished"]
      [(eq? end 'stopped) "stopped"]
      [(and (fixnum? end) (fx> end 0)) (format "exited with code ~a" end)]
      [(fixnum? end) (format "ended by signal ~a" (fx- 0 end))]
      [else "could not start"]))

  (define (end-message end)
    (cond
      [(string? end) end]
      [(and (condition? end) (message-condition? end)) (condition-message end)]
      [else "unknown failure"]))

  (define (footer r)
    (let* ([end (run-end r)] [words (end-words end)] [at (time-text (run-ended-at r))])
      (values
        (cond
          [(eqv? end 0)
           (format "Run ~a at ~a, after ~,2f s" words at (- (run-ended-at r) (run-started r)))]
          [(or (fixnum? end) (eq? end 'stopped)) (format "Run ~a at ~a" words at)]
          [else (format "Run ~a: ~a" words (end-message end))])
        words
        (cond [(eqv? end 0) faces:success] [(eq? end 'stopped) faces:warning] [else faces:error]))))

  (define (end-position b) (fx- (document:length (buffers:document b)) 1))

  (define (append-text! b text spans)
    (let ([at (end-position b)])
      (buffers:splice! b at at (document:from-datum text))
      (unless (null? spans)
        (buffers:set-spans! (buffers:layer b %styles) at (fx+ at (string-length text))
          (map (lambda (s) (list (fx+ at (car s)) (fx+ at (cadr s)) (caddr s))) spans)))))

  (define (ends-line? b)
    (let ([doc (buffers:document b)] [at (end-position b)])
      (or (fx<= at 1) (eqv? (document:token doc (fx- at 1)) #\newline))))

  (define (write-footer! b r)
    (let-values ([(text words face) (footer r)])
      (let ([lead (if (ends-line? b) "\n" "\n\n")])
        (append-text! b (string-append lead text "\n")
          (let ([start (fx+ (string-length lead) 4)])
            (list (list start (fx+ start (string-length words)) (list (cons 'face face)))))))))

  (define (make-run-buffer! name r text)
    (let ([b (buffers:make name (%output (list (cons 'run (run-number r))) text))])
      (buffers:set-silent! b #t)
      b))

  ;; The current line's start is an anchor, so an output-written entry's
  ;; edit before it moves it.
  (define (write-stretches! b r stretches)
    (let* ([line-start (buffers:anchor-position (run-line-start r))]
           [end (end-position b)]
           [kept (fx- end line-start)]
           [old? #t] [cr? (run-cr? r)] [out '()] [out-length 0] [line-out-start 0])
      (define (truncate! n)
        (let loop ()
          (when (fx> out-length n)
            (let* ([seg (car out)] [len (string-length (car seg))] [before (fx- out-length len)])
              (if (fx< before n)
                  (begin
                    (set! out (cons (cons (substring (car seg) 0 (fx- n before)) (cdr seg)) (cdr out)))
                    (set! out-length n))
                  (begin
                    (set! out (cdr out))
                    (set! out-length before)
                    (loop)))))))
      (define (clear-line!)
        (when old? (set! kept 0))
        (truncate! line-out-start))
      (for-each
        (lambda (stretch)
          (let ([text (car stretch)] [value (cdr stretch)])
            (define (flush! from to)
              (when (fx< from to)
                (set! out (cons (cons (substring text from to) value) out))
                (set! out-length (fx+ out-length (fx- to from)))))
            (let ([n (string-length text)])
              (let loop ([i 0] [from 0])
                (if (fx= i n)
                    (flush! from n)
                    (let ([c (string-ref text i)])
                      (cond
                        [(char=? c #\return)
                         (flush! from i)
                         (set! cr? #t)
                         (loop (fx+ i 1) (fx+ i 1))]
                        [(char=? c #\backspace)
                         (flush! from i)
                         (cond
                           [(fx> out-length line-out-start) (truncate! (fx- out-length 1))]
                           [(and old? (fx> kept 0)) (set! kept (fx- kept 1))])
                         (loop (fx+ i 1) (fx+ i 1))]
                        [(char=? c #\newline)
                         (set! cr? #f)
                         (set! old? #f)
                         (set! line-out-start (fx+ out-length (fx- i from) 1))
                         (loop (fx+ i 1) from)]
                        [cr?
                         (set! cr? #f)
                         (clear-line!)
                         (loop (fx+ i 1) from)]
                        [else (loop (fx+ i 1) from)])))))))
        stretches)
      (run-cr?-set! r cr?)
      (let ([from (fx+ line-start kept)] [segments (reverse out)])
        (unless (and (fx= from end) (null? segments))
          (let ([text (apply string-append (map car segments))])
            (buffers:splice! b from end (document:from-datum text))
            (buffers:set-spans! (buffers:layer b %styles) from (fx+ from (string-length text))
              (if (buffers:with-buffer b (colors?))
                  (let loop ([segments segments] [at from] [spans '()])
                    (if (null? segments)
                        (reverse spans)
                        (let* ([seg (car segments)] [next (fx+ at (string-length (car seg)))])
                          (loop (cdr segments) next
                                (if (cdr seg) (cons (list at next (cdr seg)) spans) spans)))))
                  '()))
            (unless old?
              (buffers:set-anchor! (run-line-start r) (fx+ from line-out-start)))
            (buffers:with-buffer b (output-written b from (fx+ from (string-length text)))))))))

  (define (receive! b r text end)
    (when (and (going? r) (buffers:live? b) (eq? (run-of b) r))
      (run-stretches-set! r '())
      ((run-filter r) text)
      (run-offset-set! r end)
      (write-stretches! b r (reverse (run-stretches r)))))

  (define (new-filter r)
    (ansi-colors:filter (lambda (text value) (run-stretches-set! r (cons (cons text value) (run-stretches r))))))

  ;; Tuna's dynamic-wind runs its in with quits held off, so the end, its
  ;; footer and the ended entries are never split by a quit, nor a start
  ;; between the program and the run that follows it.
  (define (hold-quits thunk)
    (let ([result #f])
      (dynamic-wind (lambda () (set! result (thunk))) void void)
      result))

  (define (end-run! b r end footer?)
    (hold-quits
      (lambda ()
        (when (going? r)
          (run-end-set! r end)
          (run-ended-at-set! r (now))
          (when (and footer? (buffers:live? b) (eq? (run-of b) r))
            (write-footer! b r))
          (if (buffers:live? b)
              (buffers:with-buffer b (ended b end))
              (ended b end))))))

  (define (stop-run! b r footer?)
    (let ([p (run-process r)])
      (when p (processes:stop! p)))
    (end-run! b r 'stopped footer?))

  (define (attach! b r from)
    (let ([receiver (processes:text-receiver from
                      (lambda (text end) (unless (eof-object? text) (receive! b r text end))))])
      (as-module (this-module)
        (processes:attach! (run-process r) from receiver
          (lambda (status) (end-run! b r status #t))))))

  (define (merged-environment given)
    (fold-left
      (lambda (acc change) (append (remp (lambda (e) (string=? (car e) (car change))) acc) (list change)))
      '() (append (environment) (or given '()))))

  (define (program-line command)
    (if (string? command) (append (shell) (list command)) command))

  ;; files:directory gives a run's folder to projects:find, which walks it
  ;; upward as text, so it is recorded absolute with no . or .. in it.
  (define (start-folder options)
    (files:expanded-path (or (processes:options-directory options) (current-directory))))

  ;; The program starts before the buffer changes, so whatever processes
  ;; refuses leaves the buffer as it was; its output waits in the log
  ;; until the run attaches from 0.
  (define (start-run! b name command directory options major-mode owner)
    (hold-quits
      (lambda ()
        (start-held! b name command directory options major-mode owner))))

  (define (start-held! b name command directory options major-mode owner)
    (let* ([given (processes:options-environment options)]
           [line (program-line command)]
           [p (processes:start-for-user (car line) (cdr line)
                (processes:options [directory directory] [environment (merged-environment given)]
                                   [full-log (processes:full-log pause)]))])
      ;; A raise before the run follows the program would leave it going
      ;; with no buffer to stop it from.
      (with-exception-handler
        (lambda (c)
          (when (serious-condition? c) (processes:stop! p))
          (raise-continuable c))
        (lambda ()
          (processes:close-input! p)
          (set! last-number (fx+ last-number 1))
          (let* ([r (make-run last-number p command major-mode owner directory given (now) 0 #f #f #f #f #f '() #f)]
                 [b (if b
                        (begin
                          (buffers:splice! b 0 (document:length (buffers:document b))
                            (document:from-datum (%output (list (cons 'run (run-number r))) (header r))))
                          (buffers:set-spans! (buffers:layer b %styles) 0 (document:length (buffers:document b)) '())
                          b)
                        (make-run-buffer! name r (header r)))])
            (unless (eq? (modes:major-mode b) major-mode)
              (modes:set-major-mode major-mode b))
            (run-line-start-set! r (buffers:anchor b (end-position b)))
            (run-filter-set! r (new-filter r))
            (eq-hashtable-set! runs b r)
            (attach! b r 0)
            (processes:set-buffer! p b)
            b)))))

  (define (own-runs owner)
    (let-values ([(bs rs) (hashtable-entries runs)])
      (let loop ([i 0] [acc '()])
        (if (fx= i (vector-length bs))
            acc
            (loop (fx+ i 1)
                  (let ([r (vector-ref rs i)])
                    (if (and (going? r) (equal? (run-owner r) owner))
                        (cons (cons (vector-ref bs i) r) acc)
                        acc)))))))

  (define (forget-killed! b)
    (let ([r (run-of b)])
      (when r
        (run-killed?-set! r #t)
        (when (going? r) (stop-run! b r #f))
        (eq-hashtable-delete! runs b))))

  (define (saved-end end)
    (if (condition? end) (end-message end) end))

  (define (save-runs!)
    (set-saved! %saved-runs
      (cons* (get-process-id) last-number
        (fold-right
          (lambda (b acc)
            (let ([r (run-of b)])
              (if r
                  (cons (list (run-number r) (buffers:name b) (and (run-process r) (processes:id (run-process r)))
                              (run-command r) (run-mode r) (run-owner r) (run-directory r) (run-environment r)
                              (run-offset r) (saved-end (run-end r)) (run-started r) (run-ended-at r))
                        acc)
                  acc)))
          '() (buffers:all)))))

  (define (restore-run! entry b)
    (apply
      (lambda (number name id command major-mode owner directory environment offset end started ended-at)
        (let* ([p (and id (processes:find id))]
               [r (make-run number p command major-mode owner directory environment started
                            offset end ended-at #f #f #f '() #f)])
          (cond
            [b
             (eq-hashtable-set! runs b r)
             (run-line-start-set! r (buffers:anchor b (last-line-start b)))
             (run-filter-set! r (new-filter r))
             (when (going? r)
               (if p
                   (attach! b r offset)
                   (end-run! b r (lost-end) #t)))]
            [else
             (let ([b (make-run-buffer! (buffers:free-name name) r (header r))])
               (modes:set-major-mode mode b)
               (eq-hashtable-set! runs b r)
               (run-line-start-set! r (buffers:anchor b (end-position b)))
               (run-filter-set! r (new-filter r))
               (cond
                 [(and (going? r) p)
                  (processes:set-buffer! p b)
                  (attach! b r 0)]
                 [else
                  (append-text! b "Output lost when buffers reloaded\n" '())
                  (if (going? r)
                      (end-run! b r (lost-end) #t)
                      (write-footer! b r))]))])))
      entry))

  (define (lost-end)
    (condition (make-who-condition 'runs) (make-message-condition "the program's end was lost while runs was off")))

  (define (last-line-start b)
    (let ([doc (buffers:document b)])
      (let loop ([p (end-position b)])
        (if (or (fx<= p 1) (eqv? (document:token doc (fx- p 1)) #\newline))
            p
            (loop (fx- p 1))))))

  (define (restore-runs!)
    (let ([saved (%saved-runs)])
      (when (and (pair? saved) (eqv? (car saved) (get-process-id)))
        (set! last-number (cadr saved))
        (let ([by-number (make-eqv-hashtable)])
          (for-each
            (lambda (b) (let ([n (buffer-number b)]) (when n (hashtable-set! by-number n b))))
            (buffers:all))
          (for-each
            (lambda (entry) (restore-run! entry (hashtable-ref by-number (car entry) #f)))
            (cddr saved)))))))

(import %internals)

(define (shell-quote-argument argument)
  (unless (string? argument)
    (assertion-violation 'runs:shell-quote-argument "not a string" argument))
  (if (and (fx> (string-length argument) 0)
           (for-all (lambda (c) (or (char-alphabetic? c) (char-numeric? c) (memv c (string->list "_-./=:,+@%"))))
                    (string->list argument)))
      argument
      (let loop ([chars (string->list argument)] [acc '(#\')])
        (cond
          [(null? chars) (list->string (reverse (cons #\' acc)))]
          [(char=? (car chars) #\') (loop (cdr chars) (append (reverse (string->list "'\\''")) acc))]
          [else (loop (cdr chars) (cons (car chars) acc))]))))

(define (command-text command)
  (check-command 'runs:command-text command)
  (quoted-line command))

(define %no-options (processes:options))

;; One unload action per owner stops all its runs, so a thousand runs
;; make one change, not a thousand.
(define %owners-with-action '())

(define (%stop-own-runs! owner)
  (set! %owners-with-action (remove owner %owners-with-action))
  (for-each (lambda (entry) (stop-run! (car entry) (cdr entry) #t)) (own-runs owner)))

(define (%start who name command options major-mode owner)
  (check-main-thread who)
  (unless (string? name)
    (assertion-violation who "not a string" name))
  (check-command who command)
  (unless (processes:options? options)
    (assertion-violation who "not processes:options" options))
  (when (or (processes:options-terminal options) (processes:options-separate-stderr options)
            (processes:options-full-log options))
    (assertion-violation who "options other than a directory and an environment" options))
  (unless (and (symbol? major-mode) (modes:derived? major-mode mode))
    (assertion-violation who "not a mode derived from runs:mode" major-mode))
  (let ([directory (start-folder options)])
    (let ([b (buffers:find name)])
      (when (and b (not (run-of b)))
        (assertion-violation who "a live buffer that shows no run has the name" name))
      (let ([r (and b (run-of b))])
        (when (and r (going? r))
          (unless (or (buffers:with-buffer b (always-stop?))
                      (ask:yes-or-no? (format "A run is going in ~a; stop it? " name)))
            (error who "the run goes on" name))
          (let ([r (run-of b)])
            (when (and r (going? r) (buffers:live? b))
              (stop-run! b r #t))))))
    (when (and owner (not (member owner %owners-with-action)))
      (set! %owners-with-action (cons owner %owners-with-action))
      (on-unload (lambda () (%stop-own-runs! owner))))
    (let ([b (start-run! (buffers:find name) name command directory options major-mode owner)])
      (buffers:with-buffer b (started b))
      (let ([at (if (buffers:with-buffer b (follow-output?))
                    (fx- (document:length (buffers:document b)) 1)
                    1)])
        (for-each (lambda (v) (views:set-point! v at)) (views:showing b)))
      b)))

(define start
  (case-lambda
    [(name command) (start name command %no-options mode)]
    [(name command options) (start name command options mode)]
    [(name command options major-mode) (%start 'runs:start name command options major-mode (current-owner))]))

(define start-for-user
  (case-lambda
    [(name command) (start-for-user name command %no-options mode)]
    [(name command options) (start-for-user name command options mode)]
    [(name command options major-mode) (%start 'runs:start-for-user name command options major-mode #f)]))

(commands:define-command (stop [buffer (buffers:current)])
  "Stops the run in BUFFER, which ends stopped."
  (check-main-thread 'runs:stop)
  (let ([r (check-run-buffer 'runs:stop buffer)])
    (unless (going? r)
      (error 'runs:stop "the run has ended" (buffers:name buffer)))
    (stop-run! buffer r #t)))

(define (status buffer)
  (run-end (check-run-buffer 'runs:status buffer)))

(define (command buffer)
  (run-command (check-run-buffer 'runs:command buffer)))

(define (options buffer)
  (let ([r (check-run-buffer 'runs:options buffer)])
    (processes:options [directory (run-directory r)] [environment (run-environment r)])))

(define (run-buffer? v)
  (and (buffers:buffer? v) (buffers:live? v) (run-of v) #t))

(commands:define-command (run-again [buffer (buffers:current)])
  "Starts BUFFER's command again in it, in its directory, environment and mode, as the user's run."
  (let ([r (check-run-buffer 'runs:run-again buffer)])
    (start-for-user (buffers:name buffer) (run-command r) (options buffer) (run-mode r))))

(define (tell-end buffer end)
  (unless (run-killed? (check-run-buffer 'runs:tell-end buffer))
    (ask:message (string-append (buffers:name buffer) " " (end-words end)))))

(define (%run-directory b)
  (let ([r (run-of b)])
    (and r (run-directory r))))

(define (%set-local-options)
  (set-option-local! views:point-after-insertion? #t buffers:revert-function run-again))

(add-hook! mode-hook %set-local-options)
(add-hook! ended tell-end)
(add-hook! buffers:killed forget-killed!)
(add-hook! files:directory-finders %run-directory)
(keys:bind! keymap "C-c C-k" stop)
(restore-runs!)
(on-unload save-runs!)
