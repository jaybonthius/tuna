(library (processes running)
  (export
    make-options options? options-directory options-environment options-terminal options-separate-stderr
    options-full-log options-with-separate-stderr
    process? process-id process-pid process-command-line process-kind process-owner
    process-status process-terminal process-buffer process-buffer-set! process-input-ended?
    output-end error-output foreground-group on-main-thread?
    start! start-run! attach! send! close-input! resize! stop! signal!
    all-processes find-process post-waiting-deliveries! set-log-limit! set-cancel-holder! set-poster!)
  (import (except (chezscheme) process)
          (only (tuna) call-as-owner report on-unload unloaded?)
          (prefix (process) native-))

  ;; Chez creates this library once per process, so the processes, their
  ;; threads and their output outlive every reload of the plugin and of
  ;; the modules that use it. Threads forked here act for no owner, so
  ;; what they post goes through the plugin's current instance, which
  ;; hands over its poster as it loads.
  (define poster #f)

  (define (set-poster! post) (set! poster post))

  (define main-thread (get-thread-id))

  (define (on-main-thread?) (eqv? (get-thread-id) main-thread))

  (define read-size 65536)

  ;; Small reads are joined into one chunk, so a program that writes a
  ;; byte at a time does not make the log a list of a million bytevectors.
  (define small-chunk 4096)

  (define one-second (make-time 'time-duration 0 1))

  (define end-of-file-character (bytevector 4))

  ;; Ids are kept in modules' saved data, which outlives this run of Tuna,
  ;; so they hold the time this library loaded and Tuna's process id.
  (define loaded-at (time-second (current-time 'time-utc)))
  (define tuna-pid ((foreign-procedure "getpid" () int)))
  (define count 0)

  (define limit 1048576)

  (define-record-type options
    (sealed #t)
    (fields directory environment terminal separate-stderr full-log))

  (define (options-with-separate-stderr o)
    (make-options (options-directory o) (options-environment o) (options-terminal o) #t (options-full-log o)))

  ;; A chunk handed to a module is never changed; the log replaces it
  ;; instead.
  (define-record-type byte-log
    (sealed #t)
    (fields (mutable chunks) (mutable last) (mutable start) (mutable end))
    (protocol (lambda (new) (lambda () (new '() #f 0 0)))))

  (define (bytevector-part bv start end)
    (let ([part (make-bytevector (fx- end start))])
      (bytevector-copy! bv start part 0 (fx- end start))
      part))

  (define (join chunks)
    (let ([joined (make-bytevector (fold-left (lambda (n chunk) (fx+ n (bytevector-length chunk))) 0 chunks))])
      (fold-left
        (lambda (at chunk)
          (bytevector-copy! chunk 0 joined at (bytevector-length chunk))
          (fx+ at (bytevector-length chunk)))
        0 chunks)
      joined))

  (define (byte-log-append! log bv)
    (let ([last (byte-log-last log)])
      (cond
        [(not last)
         (let ([cell (list bv)])
           (byte-log-chunks-set! log cell)
           (byte-log-last-set! log cell))]
        [(fx< (fx+ (bytevector-length (car last)) (bytevector-length bv)) small-chunk)
         (set-car! last (join (list (car last) bv)))]
        [else
         (let ([cell (list bv)])
           (set-cdr! last cell)
           (byte-log-last-set! log cell))]))
    (byte-log-end-set! log (+ (byte-log-end log) (bytevector-length bv))))

  ;; A dropped cell's cdr is cleared: once the collector has moved the
  ;; cell to an older generation, it would keep every later chunk alive
  ;; until that generation is collected, gigabytes under a flood.
  (define (byte-log-drop-before! log offset)
    (when (> offset (byte-log-start log))
      (let loop ([cell (byte-log-chunks log)] [start (byte-log-start log)])
        (cond
          [(null? cell)
           (byte-log-chunks-set! log '())
           (byte-log-last-set! log #f)
           (byte-log-start-set! log start)]
          [(<= (+ start (bytevector-length (car cell))) offset)
           (let ([next (cdr cell)] [chunk-end (+ start (bytevector-length (car cell)))])
             (set-cdr! cell '())
             (loop next chunk-end))]
          [else
           (let ([chunk (car cell)])
             (when (< start offset)
               (set-car! cell (bytevector-part chunk (- offset start) (bytevector-length chunk)))))
           (byte-log-chunks-set! log cell)
           (byte-log-start-set! log (max start offset))]))))

  ;; A range of whole chunks becomes one chunk, so later readers of the
  ;; range share it.
  (define (byte-log-bytes! log from to)
    (let loop ([cell (byte-log-chunks log)] [start (byte-log-start log)])
      (cond
        [(or (null? cell) (>= from to)) (make-bytevector 0)]
        [(<= (+ start (bytevector-length (car cell))) from)
         (loop (cdr cell) (+ start (bytevector-length (car cell))))]
        [else (byte-log-take! log cell start from to)])))

  (define (byte-log-take! log first first-start from to)
    (let take ([cell first] [start first-start] [parts '()])
      (let* ([chunk (car cell)] [chunk-end (+ start (bytevector-length chunk))]
             [part (if (and (<= from start) (<= chunk-end to))
                       chunk
                       (bytevector-part chunk (max 0 (- from start)) (- (min chunk-end to) start)))])
        (cond
          [(< chunk-end to) (take (cdr cell) chunk-end (cons part parts))]
          [(null? parts) part]
          [else
           (let ([joined (join (reverse (cons part parts)))])
             (when (and (= from first-start) (= chunk-end to))
               (set-car! first joined)
               (set-cdr! first (cdr cell))
               (set-cdr! cell '())
               (when (eq? cell (byte-log-last log))
                 (byte-log-last-set! log first)))
             joined)]))))

  (define-record-type attachment
    (sealed #t)
    (fields owner on-output on-exit (mutable next) (mutable eof-sent?) (mutable exit-sent?))
    (protocol
      (lambda (new)
        (lambda (owner on-output on-exit)
          (new owner on-output on-exit 0 #f #f)))))

  ;; The fields from native to posted are shared with the process's
  ;; threads and change only with its mutex held; attachments, buffer,
  ;; input-ended? and exit-delivered? belong to the main thread.
  (define-record-type process
    (sealed #t)
    (fields id number command-line kind owner terminal full-log mutex room input-ready output errors
            (mutable native) (mutable pid) (mutable pty) (mutable size) (mutable signals)
            (mutable status) (mutable readers) (mutable eof?) (mutable failure)
            (mutable taken) (mutable followers)
            (mutable inputs) (mutable closing?) (mutable writer?) (mutable input-closed?)
            (mutable stopped?) (mutable posted)
            (mutable attachments) (mutable buffer) (mutable input-ended?) (mutable exit-delivered?)
            (mutable start-reported?)
            (mutable on-errors) (mutable errors-next) (mutable errors-eof?) (mutable errors-eof-sent?))
    (protocol
      (lambda (new)
        (lambda (id number command-line kind owner terminal separate-stderr full-log)
          (new id number command-line kind owner terminal full-log
               (make-mutex) (make-condition) (make-condition) (make-byte-log)
               (and separate-stderr (make-byte-log))
               #f #f #f terminal '()
               #f 0 #f #f
               0 0
               '() #f #f #f
               #f #f
               '() #f #f #f
               #f
               #f 0 #f #f)))))

  (define busy (list 'busy))

  ;; A cancel can land anywhere in code on the main thread, so the main
  ;; thread holds a process's mutex only with interrupts disabled. A
  ;; blocked acquire with interrupts disabled would keep a collection
  ;; waiting for the main thread, so it only tries the mutex, which the
  ;; process's threads hold for a few instructions at a time. The body
  ;; must neither raise nor wait.
  (define-syntax with-process-mutex
    (syntax-rules ()
      [(_ p e1 e2 ...)
       (let ([m (process-mutex p)])
         (cond
           [(on-main-thread?)
            (let retry ()
              (let ([v (with-interrupts-disabled
                         (cond
                           [(mutex-acquire m #f)
                            (let ([v (begin e1 e2 ...)])
                              (mutex-release m)
                              v)]
                           [else busy]))])
                (if (eq? v busy) (retry) v)))]
           [else (with-mutex m e1 e2 ...)]))]))

  (define registry '())

  (define (all-processes) (reverse registry))

  (define (find-process id)
    (find (lambda (p) (string=? (process-id p) id)) registry))

  ;; Each owner's processes and attachments, so that one unload action per
  ;; owner releases them all.
  (define owners (make-hashtable equal-hash equal?))

  (define (remember-owner! owner p)
    (unless (hashtable-contains? owners owner)
      (on-unload (lambda () (release-owner! owner)))
      (hashtable-set! owners owner (make-eq-hashtable)))
    (eq-hashtable-set! (hashtable-ref owners owner #f) p #t))

  (define (forget-owner! owner p)
    (let ([processes (hashtable-ref owners owner #f)])
      (when processes (eq-hashtable-delete! processes p))))

  (define (release-owner! owner)
    (let ([processes (hashtable-ref owners owner #f)])
      (hashtable-delete! owners owner)
      (when processes
        (vector-for-each
          (lambda (p)
            (detach! p owner)
            (when (equal? (process-owner p) owner)
              (stop! p)))
          (hashtable-keys processes)))))

  (define (forget-process! p)
    (set! registry (remq p registry))
    (when (process-owner p) (forget-owner! (process-owner p) p))
    (for-each (lambda (a) (forget-owner! (attachment-owner a) p)) (process-attachments p)))

  (define (resolve-environment changes)
    (and changes
         (let loop ([changes changes] [seen '()] [added '()])
           (cond
             [(null? changes)
              (append (remp (lambda (binding) (member (car binding) seen)) (native-environment-variables))
                      (reverse added))]
             [(member (caar changes) seen) (loop (cdr changes) seen added)]
             [else
              (loop (cdr changes) (cons (caar changes) seen)
                (if (cdar changes) (cons (car changes) added) added))]))))

  (define (next-id!)
    (set! count (+ count 1))
    (format "~a-~a-~a" loaded-at tuna-pid count))

  (define-ftype passwd
    (struct [name uptr] [password uptr] [uid unsigned-32] [gid unsigned-32] [gecos uptr] [home uptr] [shell uptr]))

  (define (c-string address)
    (let ([n (let loop ([i 0]) (if (fx= (foreign-ref 'unsigned-8 address i) 0) i (loop (fx+ i 1))))])
      (let ([bytes (make-bytevector n)])
        (do ([i 0 (fx+ i 1)]) ((fx= i n) (utf8->string bytes))
          (bytevector-u8-set! bytes i (foreign-ref 'unsigned-8 address i))))))

  (define (foreign-string s)
    (let* ([bytes (string->utf8 s)] [n (bytevector-length bytes)] [address (foreign-alloc (fx+ n 1))])
      (do ([i 0 (fx+ i 1)]) ((fx= i n) (foreign-set! 'unsigned-8 address n 0) address)
        (foreign-set! 'unsigned-8 address i (bytevector-u8-ref bytes i)))))

  ;; The lookup can wait on a network directory, so it runs on a spawning
  ;; thread with collection allowed; getpwnam and getpwuid return one
  ;; static entry that two spawning threads would share.
  (define user-entry (foreign-procedure __collect_safe "getpwnam_r" (uptr uptr uptr size_t uptr) int))
  (define own-entry (foreign-procedure __collect_safe "getpwuid_r" (unsigned-32 uptr uptr size_t uptr) int))
  (define user-id (foreign-procedure "getuid" () unsigned-32))
  (define erange 34)

  (define (passwd-home lookup)
    (let ([entry (foreign-alloc (ftype-sizeof passwd))] [found (foreign-alloc (foreign-sizeof 'uptr))])
      (let retry ([size 1024])
        (let* ([buffer (foreign-alloc size)]
               [error (lookup entry buffer size found)]
               [home (and (fx= error 0) (not (fx= (foreign-ref 'uptr found 0) 0))
                          (c-string (ftype-ref passwd (home) (make-ftype-pointer passwd entry))))])
          (foreign-free buffer)
          (cond
            [(fx= error erange) (retry (fx* size 2))]
            [else
             (foreign-free entry)
             (foreign-free found)
             home])))))

  ;; Chez expands a leading ~ or ~user in every file name it opens, so
  ;; Tuna's paths keep the ~ as typed; the system does not expand a
  ;; program's directory.
  (define (expand-home directory)
    (if (and directory (fx> (string-length directory) 0) (char=? (string-ref directory 0) #\~))
        (let* ([n (string-length directory)]
               [end (let loop ([i 1]) (if (or (fx= i n) (char=? (string-ref directory i) #\/)) i (loop (fx+ i 1))))]
               [home (if (fx= end 1)
                         (or (getenv "HOME")
                             (passwd-home (lambda (entry buffer size found) (own-entry (user-id) entry buffer size found))))
                         (let* ([name (foreign-string (substring directory 1 end))]
                                [home (passwd-home (lambda (entry buffer size found) (user-entry name entry buffer size found)))])
                           (foreign-free name)
                           home))])
          (if home (string-append home (substring directory end n)) directory))
        directory))

  (define (start! kind program arguments options owner on-output on-exit on-errors)
    (let* ([id (next-id!)]
           [p (make-process id count (cons program arguments) kind owner
                (options-terminal options) (options-separate-stderr options)
                (or (options-full-log options) 'drop))]
           [directory (options-directory options)]
           [environment (resolve-environment (options-environment options))])
      (when owner
        (remember-owner! owner p)
        (process-attachments-set! p (list (make-attachment owner on-output on-exit)))
        (process-on-errors-set! p on-errors)
        (process-followers-set! p 1))
      (set! registry (cons p registry))
      (fork-thread (lambda () (run-child! p program arguments directory environment)))
      p))

  (define (start-run! program arguments input options owner resume)
    (let* ([id (next-id!)]
           [p (make-process id count (cons program arguments) 'run owner #f #f 'drop)]
           [directory (options-directory options)]
           [environment (resolve-environment (options-environment options))])
      (remember-owner! owner p)
      (set! registry (cons p registry))
      (fork-thread
        (lambda ()
          (run-to-end! p program arguments directory environment (options-separate-stderr options) input resume)))
      p))

  (define (status-of exit)
    (or (native-exit-status-code exit) (- (native-exit-status-signal exit))))

  (define (ended? p) (and (process-status p) (fx= (process-readers p) 0)))

  (define (unfollowed-drop? p)
    (and (eq? (process-kind p) 'user) (eq? (process-full-log p) 'drop) (fx= (process-followers p) 0)))

  ;; Called with the mutex held.
  (define (claim-delivery! p)
    (and (not (process-posted p))
         (or (fx> (process-followers p) 0) (ended? p))
         (begin (process-posted-set! p 'waiting) #t)))

  ;; The plugin's module hands over its mask as it loads, so a cancel
  ;; cannot split a change to a process.
  (define without-cancels #f)

  (define (set-cancel-holder! hold) (set! without-cancels hold))

  ;; Posting fails while the plugin is off; its body posts what waits when
  ;; it loads again.
  (define (post-delivery! p)
    (unless (guard (c [(unloaded? c) #f])
              (and poster (begin (poster (lambda () (without-cancels (lambda () (deliver! p))))) #t)))
      (with-process-mutex p (process-posted-set! p #f))))

  (define (post-waiting-deliveries!)
    (for-each
      (lambda (p)
        (when (with-process-mutex p
                (process-posted-set! p #f)
                (claim-delivery! p))
          (post-delivery! p)))
      (all-processes)))

  ;; A cancel can land in a posted delivery before it holds cancels off, and
  ;; nothing would then post the process's delivery again. One still
  ;; waiting a whole round later is posted again; a delivery that runs
  ;; twice delivers nothing twice.
  (define (post-late-deliveries!)
    (sleep one-second)
    (for-each
      (lambda (p)
        (when (with-mutex (process-mutex p)
                (case (process-posted p)
                  [(waiting) (process-posted-set! p 'late) #f]
                  [(late) (process-posted-set! p 'waiting) #t]
                  [else #f]))
          (post-delivery! p)))
      registry)
    (post-late-deliveries!))

  (define (set-log-limit! size)
    (set! limit size)
    (for-each (lambda (p) (with-process-mutex p (condition-broadcast (process-room p)))) registry))

  (define (spawn-child p program arguments directory environment)
    (let ([size (with-mutex (process-mutex p) (process-size p))] [directory (expand-home directory)])
      (cond
        [size
         (let ([pty (native-open-pty (car size) (cdr size))])
           (guard (c [#t (native-pty-close! pty) (raise c)])
             (list (native-spawn-process program arguments
                     (native-process-options [directory directory] [environment environment] [pty pty]))
                   pty size)))]
        [else
         (list (native-spawn-process program arguments
                 (native-process-options [directory directory] [environment environment]
                   [stderr (if (process-errors p) 'pipe 'stdout)] [process-group 'new]))
               #f #f)])))

  (define (run-child! p program arguments directory environment)
    (let ([spawned (guard (c [#t (end-unstarted! p c) #f])
                     (spawn-child p program arguments directory environment))])
      (when spawned
        (let-values ([(native pty opened-size) (apply values spawned)])
          ;; Only the wait reaps the program and ends the process, so a
          ;; raise before it is reported instead of ending this thread.
          (guard (c [#t (with-mutex (process-mutex p) (process-failure-set! p c))])
            (started! p native pty opened-size))
          (let ([status (status-of (native-process-wait native))])
            (when (with-mutex (process-mutex p)
                    (process-status-set! p status)
                    (condition-broadcast (process-input-ready p))
                    (claim-delivery! p))
              (post-delivery! p))
            (release-input! p))))))

  (define (started! p native pty opened-size)
    (let ([state (with-mutex (process-mutex p)
                   (process-native-set! p native)
                   (process-pid-set! p (native-process-id native))
                   (process-pty-set! p pty)
                   (process-readers-set! p (if (process-errors p) 2 1))
                   (let ([writer? (and (not (process-stopped? p))
                                       (or (pair? (process-inputs p)) (process-closing? p)))])
                     (when writer? (process-writer?-set! p #t))
                     (list (process-stopped? p) writer? (reverse (process-signals p))
                           (process-size p))))])
      (let-values ([(stopped? writer? signals size) (apply values state)])
        (fork-thread
          (lambda ()
            (read-stream! p (if pty (native-pty-input-port pty) (native-process-stdout native)) #t)))
        (when (process-errors p)
          (fork-thread (lambda () (read-stream! p (native-process-stderr native) #f))))
        (when writer? (fork-thread (lambda () (write-input! p))))
        (for-each (lambda (name) (native-process-group-signal! native name)) signals)
        (when (and pty (not (equal? size opened-size)))
          (guard (c [(native-system-error? c) (void)])
            (native-pty-resize! pty (car size) (cdr size))))
        (when stopped? (hang-up! p)))))

  (define (end-unstarted! p c)
    (when (with-mutex (process-mutex p)
            (process-status-set! p c)
            (process-eof?-set! p #t)
            (claim-delivery! p))
      (post-delivery! p)))

  (define (run-to-end! p program arguments directory environment separate-stderr input resume)
    (let ([result
           (guard (c [#t (with-mutex (process-mutex p)
                           (process-status-set! p c)
                           (process-eof?-set! p #t))
                         (lambda () (raise c))])
             (let ([native (native-spawn-process program arguments
                             (native-process-options [directory (expand-home directory)] [environment environment]
                               [stderr (if separate-stderr 'pipe 'stdout)] [process-group 'new]))])
               (when (with-mutex (process-mutex p)
                       (process-native-set! p native)
                       (process-pid-set! p (native-process-id native))
                       (process-stopped? p))
                 (hang-up! p))
               (let* ([r (native-process-communicate native input)]
                      [status (status-of (native-process-result-status r))]
                      [out (native-process-result-stdout r)]
                      [err (or (native-process-result-stderr r) (bytevector))])
                 (with-mutex (process-mutex p)
                   (process-status-set! p status)
                   (process-eof?-set! p #t))
                 (lambda () (values status out err)))))])
      ;; The delivery, which takes the process out of the list, is posted
      ;; first, so it runs before the caller resumes.
      (when (with-mutex (process-mutex p) (claim-delivery! p))
        (post-delivery! p))
      (resume result)))

  ;; Called with the mutex held.
  (define (room p)
    (if (or (process-stopped? p) (unfollowed-drop? p))
        read-size
        (max 0 (min read-size (- limit (- (byte-log-end (process-output p)) (process-taken p)))))))

  (define (read-stream! p port output?)
    (let ([buffer (make-bytevector read-size)])
      (let loop ()
        (let* ([wanted (if output?
                          (with-mutex (process-mutex p)
                            (let wait ()
                              (let ([n (room p)])
                                (cond
                                  [(fx> n 0) n]
                                  [else (condition-wait (process-room p) (process-mutex p)) (wait)]))))
                          read-size)]
               [n (guard (c [#t (with-mutex (process-mutex p)
                                  (unless (process-stopped? p) (process-failure-set! p c)))
                                (eof-object)])
                    (get-bytevector-some! port buffer 0 wanted))])
          (cond
            [(eof-object? n)
             (close-port port)
             (reader-ended! p output?)]
            [output? (add-output! p (bytevector-part buffer 0 n)) (loop)]
            [else (add-errors! p (bytevector-part buffer 0 n)) (loop)])))))

  (define (add-output! p bytes)
    (when (with-mutex (process-mutex p)
            (and (not (process-stopped? p))
                 (let ([output (process-output p)])
                   (byte-log-append! output bytes)
                   (when (unfollowed-drop? p)
                     (byte-log-drop-before! output (- (byte-log-end output) limit)))
                   (claim-delivery! p))))
      (post-delivery! p)))

  (define (add-errors! p bytes)
    (when (with-mutex (process-mutex p)
            (let ([errors (process-errors p)])
              (byte-log-append! errors bytes)
              (byte-log-drop-before! errors (- (byte-log-end errors) limit))
              (and (process-on-errors p) (not (process-stopped? p)) (claim-delivery! p))))
      (post-delivery! p)))

  (define (reader-ended! p output?)
    (when (with-mutex (process-mutex p)
            (process-readers-set! p (fx- (process-readers p) 1))
            (if output? (process-eof?-set! p #t) (process-errors-eof?-set! p #t))
            (claim-delivery! p))
      (post-delivery! p)))

  ;; Standard error is not held back for a slow reader, as output is,
  ;; since a program that blocks writing it would stop; past the log's
  ;; size, the oldest is lost.
  (define (deliver-errors! p)
    (let ([on-errors (process-on-errors p)])
      (when (and on-errors (not (process-stopped? p)))
        (let-values ([(bytes end eof?)
                      (apply values
                        (with-process-mutex p
                          (let* ([errors (process-errors p)]
                                 [end (byte-log-end errors)]
                                 [from (max (process-errors-next p) (byte-log-start errors))])
                            (process-errors-next-set! p end)
                            (list (and (< from end) (byte-log-bytes! errors from end)) end
                                  (process-errors-eof? p)))))])
          (when bytes (call-as-owner (process-owner p) (lambda () (on-errors bytes end))))
          (when (and eof? (not (process-errors-eof-sent? p)))
            (process-errors-eof-sent?-set! p #t)
            (call-as-owner (process-owner p) (lambda () (on-errors (eof-object) end))))))))

  (define (input-port p)
    (let ([pty (process-pty p)])
      (if pty (native-pty-output-port pty) (native-process-stdin (process-native p)))))

  ;; Only the thread that writes the input closes it, since closing a port
  ;; first writes what it holds, which could wait on a program that does
  ;; not read.
  (define (release-input! p)
    (when (with-process-mutex p
            (cond
              [(process-input-closed? p) #f]
              [(process-writer? p) (condition-broadcast (process-input-ready p)) #f]
              [else (process-input-closed?-set! p #t) #t]))
      (close-port (input-port p))))

  (define (write-input! p)
    (let ([port (input-port p)])
      (define (write-all inputs)
        (guard (c [(i/o-error? c) #f])
          (for-each (lambda (bv) (put-bytevector port bv)) inputs)
          (flush-output-port port)
          #t))
      (define (close!)
        (with-mutex (process-mutex p) (process-input-closed?-set! p #t))
        (guard (c [(i/o-error? c) (void)])
          (clear-output-port port)
          (close-port port)))
      (let loop ()
        (let ([next (with-mutex (process-mutex p)
                      (let wait ()
                        (cond
                          [(or (process-stopped? p) (process-status p)) 'close]
                          [(pair? (process-inputs p))
                           (let ([inputs (reverse (process-inputs p))])
                             (process-inputs-set! p '())
                             inputs)]
                          [(process-closing? p) (process-closing?-set! p #f) 'end]
                          [else (condition-wait (process-input-ready p) (process-mutex p)) (wait)])))])
          (cond
            [(pair? next) (if (write-all next) (loop) (close!))]
            [(and (eq? next 'end) (process-pty p))
             (if (write-all (list end-of-file-character)) (loop) (close!))]
            [else (close!)])))))

  ;; Called with the mutex held.
  (define (start-writer? p)
    (and (process-native p)
         (not (process-writer? p))
         (begin (process-writer?-set! p #t) #t)))

  (define (send! p bytes)
    (when (with-process-mutex p
            (and (not (process-stopped? p))
                 (not (process-status p))
                 (not (process-input-closed? p))
                 (begin
                   (process-inputs-set! p (cons bytes (process-inputs p)))
                   (condition-signal (process-input-ready p))
                   (start-writer? p))))
      (fork-thread (lambda () (write-input! p)))))

  (define (close-input! p)
    (process-input-ended?-set! p #t)
    (when (with-process-mutex p
            (and (not (process-input-closed? p))
                 (begin
                   (process-closing?-set! p #t)
                   (condition-signal (process-input-ready p))
                   (start-writer? p))))
      (fork-thread (lambda () (write-input! p)))))

  (define (resize! p rows columns)
    (let ([pty (with-process-mutex p
                 (process-size-set! p (cons rows columns))
                 (and (not (process-stopped? p)) (not (process-status p)) (process-pty p)))])
      (when pty
        (guard (c [(native-system-error? c) (void)])
          (native-pty-resize! pty rows columns)))))

  (define (signal! p name)
    (let ([native (with-process-mutex p
                    (cond
                      [(process-status p) #f]
                      [(process-native p)]
                      [else (process-signals-set! p (cons name (process-signals p))) #f]))])
      (when native (native-process-group-signal! native name))))

  ;; A shell's foreground job is in a group of its own, which the group's
  ;; signal misses; closing the terminal's master makes the kernel hang up
  ;; the session, which ends it.
  (define (hang-up! p)
    (let ([native (process-native p)] [pty (process-pty p)])
      (unless (process-status p)
        (native-process-group-signal! native 'hup)
        (fork-thread
          (lambda ()
            (unless (native-process-wait native one-second)
              (guard (c [(native-system-error? c) (void)])
                (native-process-group-signal! native 'kill))))))
      (if pty
          (close-port (native-pty-input-port pty))
          (for-each (lambda (port) (when port (close-port port)))
            (list (native-process-stdout native) (native-process-stderr native))))
      (release-input! p)))

  (define (stop! p)
    (when (with-process-mutex p
            (and (not (process-stopped? p))
                 (begin
                   (process-stopped?-set! p #t)
                   (condition-broadcast (process-room p))
                   (condition-broadcast (process-input-ready p))
                   (and (process-native p) #t))))
      (hang-up! p))
    (when (and (eq? (process-kind p) 'user) (process-status p) (null? (process-attachments p)))
      (forget-process! p)))

  (define (foreground-group p)
    (let ([pty (process-pty p)])
      (and pty (not (process-status p)) (not (process-stopped? p))
           (guard (c [(native-system-error? c) #f])
             (native-pty-foreground-process-group pty)))))

  (define (output-end p) (byte-log-end (process-output p)))

  (define (error-output p)
    (let ([errors (process-errors p)])
      (and errors
           (with-process-mutex p (byte-log-bytes! errors (byte-log-start errors) (byte-log-end errors))))))

  ;; Called with the mutex held, after the attachments changed or took
  ;; output: a process nobody follows keeps the mark its last attachment
  ;; reached, so one that pauses holds what it has not delivered.
  (define (followers-changed! p attachments)
    (process-followers-set! p (length attachments))
    (unless (null? attachments)
      (process-taken-set! p (apply min (map attachment-next attachments))))
    (let* ([output (process-output p)] [end (byte-log-end output)])
      (byte-log-drop-before! output
        (cond
          [(not (eq? (process-kind p) 'user)) (process-taken p)]
          [(unfollowed-drop? p) (- end limit)]
          [else (min (process-taken p) (- end limit))])))
    (condition-broadcast (process-room p)))

  (define (attach! p owner from on-output on-exit)
    (remember-owner! owner p)
    (let* ([a (make-attachment owner on-output on-exit)]
           [attachments (append (remp (lambda (b) (equal? (attachment-owner b) owner))
                                  (process-attachments p))
                                (list a))])
      (let ([start (with-process-mutex p
                     (let ([start (max from (byte-log-start (process-output p)))])
                       (attachment-next-set! a start)
                       (followers-changed! p attachments)
                       start))])
        (process-attachments-set! p attachments)
        (when (with-process-mutex p (claim-delivery! p))
          (post-delivery! p))
        start)))

  (define (detach! p owner)
    (let ([attachments (remp (lambda (a) (equal? (attachment-owner a) owner)) (process-attachments p))])
      (process-attachments-set! p attachments)
      (with-process-mutex p (followers-changed! p attachments))))

  (define (call-back a procedure . arguments)
    (call-as-owner (attachment-owner a) (lambda () (apply procedure arguments))))

  (define (deliver! p)
    (let ([state (with-process-mutex p
                   (process-posted-set! p #f)
                   (let ([failure (process-failure p)])
                     (process-failure-set! p #f)
                     (list failure (byte-log-end (process-output p)) (process-eof? p)
                           (and (ended? p) (process-status p)))))])
      (let-values ([(failure end eof? status) (apply values state)])
        (when failure (report failure))
        (deliver-errors! p)
        (when (and status (not (integer? status)) (not (eq? (process-kind p) 'run))
                   (not (process-stopped? p)) (not (process-start-reported? p)))
          (process-start-reported?-set! p #t)
          (if (process-owner p)
              (call-as-owner (process-owner p) (lambda () (report status)))
              (report status)))
        (let ([attachments (process-attachments p)] [shared '()])
          (define (attached? a) (memq a (process-attachments p)))
          (define (bytes-from from)
            (cond
              [(assv from shared) => cdr]
              [else
               (let ([bytes (with-process-mutex p (byte-log-bytes! (process-output p) from end))])
                 (set! shared (cons (cons from bytes) shared))
                 bytes)]))
          (for-each
            (lambda (a)
              (when (and (attached? a) (< (attachment-next a) end))
                (let ([from (attachment-next a)])
                  (attachment-next-set! a end)
                  (unless (process-stopped? p)
                    (call-back a (attachment-on-output a) (bytes-from from) end))))
              (when (and eof? (attached? a) (not (attachment-eof-sent? a)))
                (attachment-eof-sent?-set! a #t)
                (unless (process-stopped? p)
                  (call-back a (attachment-on-output a) (eof-object) end)))
              (when (and status (attached? a) (not (attachment-exit-sent? a)))
                (attachment-exit-sent?-set! a #t)
                (process-exit-delivered?-set! p #t)
                (call-back a (attachment-on-exit a) status)))
            attachments)
          (let ([attachments (process-attachments p)])
            (with-process-mutex p (followers-changed! p attachments))))
        (when (and status (or (not (eq? (process-kind p) 'user)) (process-exit-delivered? p)))
          (forget-process! p)))))

  (record-writer (record-type-descriptor options)
    (lambda (o port write) (display "#<processes:options>" port)))

  (record-writer (record-type-descriptor process)
    (lambda (p port write)
      (fprintf port "#<process ~a ~a>" (process-number p) (car (process-command-line p)))))

  (fork-thread post-late-deliveries!))
