#!tuna
(import (buffers) (prefix (processes running) running:))

(define-option log-size 1048576 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many bytes of output Tuna holds per process."
  running:set-log-limit!)

(define-enumeration full-log (pause drop) %full-log-actions)

(define-enumeration signal (hup int quit kill term cont stop tstp usr1 usr2) %signals)

(module %internals
  (check-main-thread check-process check-procedure input-bytes environment-changes? make-checked-options no-options
   ignore-exit hold-quits start-own start-user run-program attach-from offset? first-line)

  (define (check-main-thread who)
    (unless (running:on-main-thread?)
      (assertion-violation who "not on the main thread")))

  (define (check-process who v)
    (unless (running:process? v)
      (assertion-violation who "not a process" v)))

  (define (c-string? s)
    (and (string? s)
         (let loop ([i 0])
           (or (fx= i (string-length s))
               (and (not (char=? (string-ref s i) #\nul)) (loop (fx+ i 1)))))))

  (define (check-command who program arguments)
    (unless (c-string? program)
      (assertion-violation who "not a string free of NUL characters" program))
    (unless (and (list? arguments) (for-all c-string? arguments))
      (assertion-violation who "not a list of strings free of NUL characters" arguments)))

  (define (offset? v) (and (integer? v) (exact? v) (>= v 0)))

  (define (check-procedure who v)
    (unless (procedure? v)
      (assertion-violation who "not a procedure" v)))

  (define (check-options who v)
    (unless (running:options? v)
      (assertion-violation who "not processes:options" v)))

  (define (input-bytes who input)
    (cond
      [(string? input) (string->utf8 input)]
      [(bytevector? input) input]
      [else (assertion-violation who "not a string or bytevector" input)]))

  (define (environment-change? change)
    (and (pair? change)
         (c-string? (car change))
         (fx> (string-length (car change)) 0)
         (not (memv #\= (string->list (car change))))
         (or (not (cdr change)) (c-string? (cdr change)))))

  (define (environment-changes? v)
    (and (list? v) (for-all environment-change? v)))

  (define (dimension? v) (and (fixnum? v) (fx<= 0 v 65535)))

  (define (make-checked-options directory environment terminal separate-stderr full-log)
    (define who 'processes:options)
    (unless (or (not directory) (c-string? directory))
      (assertion-violation who "not a directory string or #f" directory))
    (unless (or (not environment) (environment-changes? environment))
      (assertion-violation who "not an association list of variable names and values" environment))
    (unless (or (not terminal) (and (pair? terminal) (dimension? (car terminal)) (dimension? (cdr terminal))))
      (assertion-violation who "not a pair of rows and columns from 0 to 65535, or #f" terminal))
    (unless (boolean? separate-stderr)
      (assertion-violation who "not a boolean" separate-stderr))
    (unless (or (not full-log) (memq full-log (enum-set->list (enum-set-universe (%full-log-actions)))))
      (assertion-violation who "not a processes:full-log action or #f" full-log))
    (when (and terminal separate-stderr)
      (assertion-violation who "a terminal joins standard error to the output" terminal))
    (running:make-options directory environment terminal separate-stderr full-log))

  (define no-options (running:make-options #f #f #f #f #f))

  (define (ignore-exit status) (void))

  ;; Tuna's dynamic-wind runs its in with quits held off. A quit landing
  ;; between the steps of a change to a process would leave it half made,
  ;; such as input queued that no thread writes, and one landing in a
  ;; delivery would lose output its modules never see again.
  (define (hold-quits thunk)
    (let ([result #f])
      (dynamic-wind (lambda () (set! result (thunk))) void void)
      result))

  ;; A raise is reported, as a hook reports an entry's, so the other
  ;; modules following the process still get theirs.
  (define (reporting procedure)
    (lambda arguments
      (call/cc
        (lambda (k)
          (with-exception-handler
            (lambda (c)
              (report c)
              (unless (and (warning? c) (not (serious-condition? c)))
                (k (void))))
            (lambda () (apply procedure arguments)))))))

  (define (start-own program arguments on-output on-exit options)
    (check-main-thread 'processes:start)
    (check-command 'processes:start program arguments)
    (check-procedure 'processes:start on-output)
    (check-procedure 'processes:start on-exit)
    (check-options 'processes:start options)
    (hold-quits
      (lambda ()
        (running:start! 'own program arguments options (current-owner)
          (reporting on-output) (reporting on-exit)))))

  (define (start-user program arguments options)
    (check-main-thread 'processes:start-for-user)
    (check-command 'processes:start-for-user program arguments)
    (check-options 'processes:start-for-user options)
    (hold-quits (lambda () (running:start! 'user program arguments options #f #f #f))))

  ;; A quit or raise that ends the task, such as the quit an unload sends,
  ;; reaches the task where it paused, and stops the program on its way.
  (define (run-program program arguments input options)
    (check-command 'processes:run program arguments)
    (check-options 'processes:run options)
    (when (running:options-terminal options)
      (assertion-violation 'processes:run "a program run to its end has no terminal" options))
    (let ([bytes (and input (input-bytes 'processes:run input))] [process #f])
      (with-exception-handler
        (lambda (c)
          (when process (running:stop! process))
          (raise-continuable c))
        (lambda ()
          (suspend
            (lambda (resume)
              (hold-quits
                (lambda ()
                  (set! process
                    (running:start-run! program arguments bytes options (current-owner) resume))))))))))

  (define (first-line bytes)
    (let ([text (utf8->string bytes)])
      (let loop ([i 0])
        (cond
          [(fx= i (string-length text)) text]
          [(char=? (string-ref text i) #\newline) (substring text 0 i)]
          [else (loop (fx+ i 1))]))))

  (define (attach-from process from on-output on-exit)
    (check-main-thread 'processes:attach!)
    (check-process 'processes:attach! process)
    (unless (eq? (running:process-kind process) 'user)
      (assertion-violation 'processes:attach! "not a user process" process))
    (unless (offset? from)
      (assertion-violation 'processes:attach! "not an output offset" from))
    (unless (<= from (running:output-end process))
      (assertion-violation 'processes:attach! "past the output read so far" from))
    (check-procedure 'processes:attach! on-output)
    (check-procedure 'processes:attach! on-exit)
    (hold-quits
      (lambda () (running:attach! process (current-owner) from (reporting on-output) (reporting on-exit))))))

(import %internals)

(define-syntax options
  (lambda (x)
    (define names '(directory environment terminal separate-stderr full-log))
    (define (check-names given)
      (let loop ([given given] [seen '()])
        (unless (null? given)
          (let ([name (syntax->datum (car given))])
            (unless (memq name names)
              (syntax-violation 'processes:options "unknown clause" x (car given)))
            (when (memq name seen)
              (syntax-violation 'processes:options "clause given twice" x (car given)))
            (loop (cdr given) (cons name seen))))))
    (syntax-case x ()
      [(_ [name value] ...)
       (for-all identifier? #'(name ...))
       (begin
         (check-names #'(name ...))
         (with-syntax ([(temporary ...) (generate-temporaries #'(name ...))])
           (with-syntax ([(argument ...)
                          (let ([given (map cons (syntax->datum #'(name ...)) #'(temporary ...))])
                            (map (lambda (name) (cond [(assq name given) => cdr] [else #'#f])) names))])
             #'(let* ([temporary value] ...) (make-checked-options argument ...)))))]
      [_ (syntax-violation 'processes:options "expected (processes:options [name value] ...)" x)])))

(define (options? v) (running:options? v))

(define (environment? v) (environment-changes? v))

(define (options-directory options)
  (unless (running:options? options)
    (assertion-violation 'processes:options-directory "not processes:options" options))
  (running:options-directory options))

(define (options-environment options)
  (unless (running:options? options)
    (assertion-violation 'processes:options-environment "not processes:options" options))
  (running:options-environment options))

(define (options-terminal options)
  (unless (running:options? options)
    (assertion-violation 'processes:options-terminal "not processes:options" options))
  (running:options-terminal options))

(define (options-separate-stderr options)
  (unless (running:options? options)
    (assertion-violation 'processes:options-separate-stderr "not processes:options" options))
  (running:options-separate-stderr options))

(define (options-full-log options)
  (unless (running:options? options)
    (assertion-violation 'processes:options-full-log "not processes:options" options))
  (running:options-full-log options))

(define start
  (case-lambda
    [(program arguments on-output) (start-own program arguments on-output ignore-exit no-options)]
    [(program arguments on-output on-exit)
     (start-own program arguments on-output on-exit no-options)]
    [(program arguments on-output on-exit options)
     (start-own program arguments on-output on-exit options)]))

(define start-for-user
  (case-lambda
    [(program arguments) (start-user program arguments no-options)]
    [(program arguments options) (start-user program arguments options)]))

(define run
  (case-lambda
    [(program arguments) (run-program program arguments #f no-options)]
    [(program arguments input) (run-program program arguments input no-options)]
    [(program arguments input options) (run-program program arguments input options)]))

(define attach!
  (case-lambda
    [(process from on-output) (attach-from process from on-output ignore-exit)]
    [(process from on-output on-exit) (attach-from process from on-output on-exit)]))

;; Lines are decoded only once whole, since a chunk can end inside a
;; character.
(define line-receiver
  (case-lambda
    [(from on-line) (line-receiver from on-line 10)]
    [(from on-line separator)
     (unless (offset? from)
       (assertion-violation 'processes:line-receiver "not an output offset" from))
     (check-procedure 'processes:line-receiver on-line)
     (unless (and (fixnum? separator) (fx<= 0 separator 255))
       (assertion-violation 'processes:line-receiver "not a byte" separator))
     (let ([held '()] [skipping? #f] [first? #t] [trim? (fx= separator 10)])
       (define (line-text parts)
         (let* ([bytes (cond
                         [(null? (cdr parts)) (car parts)]
                         [else
                          (let ([joined (make-bytevector
                                          (fold-left (lambda (n part) (+ n (bytevector-length part))) 0 parts))])
                            (fold-left
                              (lambda (at part)
                                (bytevector-copy! part 0 joined at (bytevector-length part))
                                (+ at (bytevector-length part)))
                              0 parts)
                            joined)])]
                [n (bytevector-length bytes)])
           (utf8->string
             (cond
               [(and trim? (fx> n 0) (fx= (bytevector-u8-ref bytes (fx- n 1)) 13))
                (let ([trimmed (make-bytevector (fx- n 1))])
                  (bytevector-copy! bytes 0 trimmed 0 (fx- n 1))
                  trimmed)]
               [else bytes]))))
       (define (part bytes start end)
         (let ([p (make-bytevector (fx- end start))])
           (bytevector-copy! bytes start p 0 (fx- end start))
           p))
       (lambda (bytes end)
         (cond
           [(eof-object? bytes)
            (unless (or skipping? (null? held))
              (on-line (line-text (reverse held)) end))
            (set! held '())
            (on-line bytes end)]
           [else
            (let ([start (- end (bytevector-length bytes))] [n (bytevector-length bytes)])
              (when first?
                (set! first? #f)
                (set! skipping? (> start from)))
              (let loop ([i 0])
                (let scan ([j i])
                  (cond
                    [(fx= j n)
                     (unless (or skipping? (fx= i n))
                       (set! held (cons (part bytes i n) held)))]
                    [(fx= (bytevector-u8-ref bytes j) separator)
                     (cond
                       [skipping? (set! skipping? #f)]
                       [else
                        (let ([line (line-text (reverse (cons (part bytes i j) held)))])
                          (set! held '())
                          (on-line line (+ start j 1)))])
                     (loop (fx+ j 1))]
                    [else (scan (fx+ j 1))]))))])))]))

(define (text-receiver from on-text)
  (unless (offset? from)
    (assertion-violation 'processes:text-receiver "not an output offset" from))
  (check-procedure 'processes:text-receiver on-text)
  (let ([held #vu8()] [first? #t])
    (define (continuation? b) (fx= (fxand b #xC0) #x80))
    (define (sequence-length lead)
      (cond [(fx>= lead #xF0) 4] [(fx>= lead #xE0) 3] [(fx>= lead #xC0) 2] [else 1]))
    (define (cut-at bytes)
      (let ([n (bytevector-length bytes)])
        (let loop ([i (fx- n 1)])
          (cond
            [(or (fx< i 0) (fx< i (fx- n 3))) n]
            [(continuation? (bytevector-u8-ref bytes i)) (loop (fx- i 1))]
            [(fx< (fx- n i) (sequence-length (bytevector-u8-ref bytes i))) i]
            [else n]))))
    (define (skip-cut-start bytes)
      (let ([n (bytevector-length bytes)])
        (let loop ([i 0])
          (if (and (fx< i n) (continuation? (bytevector-u8-ref bytes i)))
              (loop (fx+ i 1))
              i))))
    (define (slice bytes start end)
      (let ([part (make-bytevector (fx- end start))])
        (bytevector-copy! bytes start part 0 (fx- end start))
        part))
    (lambda (bytes end)
      (cond
        [(eof-object? bytes)
         (when (fx> (bytevector-length held) 0)
           (let ([rest held])
             (set! held #vu8())
             (on-text (utf8->string rest) end)))
         (on-text bytes end)]
        [else
         (let* ([skip (cond
                        [(and first? (> (- end (bytevector-length bytes)) from)) (skip-cut-start bytes)]
                        [else 0])]
                [joined (if (and (fx= skip 0) (fx= (bytevector-length held) 0))
                            bytes
                            (let* ([n (fx- (bytevector-length bytes) skip)]
                                   [h (bytevector-length held)]
                                   [all (make-bytevector (fx+ h n))])
                              (bytevector-copy! held 0 all 0 h)
                              (bytevector-copy! bytes skip all h n)
                              all))]
                [cut (cut-at joined)])
           (set! first? #f)
           (set! held (slice joined cut (bytevector-length joined)))
           (when (fx> cut 0)
             (on-text (utf8->string (if (fx= cut (bytevector-length joined)) joined (slice joined 0 cut)))
                      (- end (bytevector-length held)))))]))))

(define (send! process input)
  (check-main-thread 'processes:send!)
  (check-process 'processes:send! process)
  (let ([bytes (input-bytes 'processes:send! input)])
    (when (running:process-input-ended? process)
      (assertion-violation 'processes:send! "the input was closed" process))
    (hold-quits (lambda () (running:send! process bytes)))
    (void)))

(define (close-input! process)
  (check-main-thread 'processes:close-input!)
  (check-process 'processes:close-input! process)
  (hold-quits (lambda () (running:close-input! process)))
  (void))

(define (resize! process rows columns)
  (check-main-thread 'processes:resize!)
  (check-process 'processes:resize! process)
  (unless (running:process-terminal process)
    (assertion-violation 'processes:resize! "not a process with a terminal" process))
  (unless (and (fixnum? rows) (fx<= 0 rows 65535))
    (assertion-violation 'processes:resize! "not a number of rows from 0 to 65535" rows))
  (unless (and (fixnum? columns) (fx<= 0 columns 65535))
    (assertion-violation 'processes:resize! "not a number of columns from 0 to 65535" columns))
  (running:resize! process rows columns)
  (void))

(define (stop! process)
  (check-main-thread 'processes:stop!)
  (check-process 'processes:stop! process)
  (hold-quits (lambda () (running:stop! process)))
  (void))

(define (signal! process name)
  (check-main-thread 'processes:signal!)
  (check-process 'processes:signal! process)
  (unless (and (symbol? name) (memq name (enum-set->list (enum-set-universe (%signals)))))
    (assertion-violation 'processes:signal! "not a processes:signal name" name))
  (running:signal! process name)
  (void))

(define (all) (running:all-processes))

(define (find id)
  (unless (string? id)
    (assertion-violation 'processes:find "not a string" id))
  (running:find-process id))

(define (id process)
  (check-process 'processes:id process)
  (running:process-id process))

(define (pid process)
  (check-process 'processes:pid process)
  (running:process-pid process))

(define (command-line process)
  (check-process 'processes:command-line process)
  (running:process-command-line process))

(define (owner process)
  (check-process 'processes:owner process)
  (running:process-owner process))

(define (status process)
  (check-process 'processes:status process)
  (running:process-status process))

(define (foreground-group process)
  (check-process 'processes:foreground-group process)
  (running:foreground-group process))

(define (output-end process)
  (check-process 'processes:output-end process)
  (running:output-end process))

(define (error-output process)
  (check-process 'processes:error-output process)
  (running:error-output process))

(define (report-error-output process who)
  (check-process 'processes:report-error-output process)
  (unless (or (symbol? who) (string? who))
    (assertion-violation 'processes:report-error-output "not a symbol or string" who))
  (let ([errors (running:error-output process)])
    (when (and errors (fx> (bytevector-length errors) 0))
      (report (condition (make-warning) (make-who-condition who) (make-message-condition (first-line errors)))))))

(define (set-buffer! process buffer)
  (check-main-thread 'processes:set-buffer!)
  (check-process 'processes:set-buffer! process)
  (unless (or (not buffer) (buffers:buffer? buffer))
    (assertion-violation 'processes:set-buffer! "not a buffer or #f" buffer))
  (running:process-buffer-set! process buffer)
  (void))

(define (buffer process)
  (check-process 'processes:buffer process)
  (let ([b (running:process-buffer process)])
    (and b (buffers:live? b) b)))

(define (process? v) (running:process? v))

(define (%stop-buffer-processes killed)
  (for-each
    (lambda (process)
      (when (eq? (running:process-buffer process) killed)
        (stop! process)))
    (all)))

(add-hook! buffers:killed %stop-buffer-processes)

(running:set-quit-holder! hold-quits)
(running:set-log-limit! (log-size))
(running:post-waiting-deliveries!)
