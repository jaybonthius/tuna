#!tuna
(import (files) (buffers) (layout) (modes) (keys) (commands) (ask) (with-editor state) (hooks) (options) (tables))

(define %self (current-owner))

(hooks:define-hook finish-checks
  "Called with the buffer before finishing; an entry that returns #f keeps the buffer open and the program waiting.")

(hooks:define-hook cancel-checks
  "Called with the buffer before canceling; an entry that returns #f keeps it open.")

(hooks:define-hook finished "Called with the file's path after finishing.")

(hooks:define-hook canceled "Called with the file's path after canceling.")

(tables:define-table keymap "Keys in a buffer a program waits for.")

(modes:define-minor-mode mode
  "Whether a program waits for this buffer: C-c C-c finishes the edit and C-c C-k cancels it."
  (keymap keymap))

(module %internals
  (script-path write-script! shell-quoted filtering request-for take-request! answer! canceled-wrapper?)

  (define (script-path) (string-append (getenv "HOME") "/.cache/tuna/with-editor.sh"))

  ;; The answer is a file renamed into place, so the script never reads
  ;; half of one, and neither standard input nor a signal can carry it: a
  ;; RET typed into a terminal while the file is open answers nothing.
  (define script
    (string-append
      "d=$(mktemp -d \"${TMPDIR:-/tmp}/tuna-edit.XXXXXX\") || exit 1\n"
      "trap 'rm -rf \"$d\"; exit 1' HUP INT TERM\n"
      "printf '%s\\n%s\\n' \"$PWD\" \"$1\" > \"$d/request\"\n"
      "printf '\\033]7563;tuna-edit;%s;%s\\007\\n' \"$TUNA_EDIT_TOKEN\" \"$d\"\n"
      "while :; do\n"
      "  if [ -e \"$d/answer\" ]; then\n"
      "    read -r answer < \"$d/answer\"; rm -rf \"$d\"; [ \"$answer\" = done ]; exit\n"
      "  fi\n"
      "  kill -0 \"$TUNA_PID\" 2>/dev/null || { rm -rf \"$d\"; exit 1; }\n"
      "  sleep 0.1\n"
      "done\n"))

  (define (make-folders! path)
    (let loop ([i 1])
      (let ([slash (let find ([j i]) (cond [(fx= j (string-length path)) #f] [(char=? (string-ref path j) #\/) j] [else (find (fx+ j 1))]))])
        (when slash
          (let ([folder (substring path 0 slash)])
            (unless (file-directory? folder) (mkdir folder)))
          (loop (fx+ slash 1))))))

  ;; sh reads a script as it runs it, so a script waiting for an answer
  ;; must never see its file rewritten in place; a new file is renamed
  ;; over it.
  (define (write-script!)
    (let* ([path (script-path)] [temporary (string-append path ".new")])
      (make-folders! path)
      (call-with-port (open-file-output-port temporary (file-options no-fail))
        (lambda (p) (put-bytevector p (string->utf8 script))))
      (rename-file temporary path)))

  (define (shell-quoted s)
    (let loop ([cs (string->list s)] [acc '(#\')])
      (cond
        [(null? cs) (list->string (reverse (cons #\' acc)))]
        [(char=? (car cs) #\') (loop (cdr cs) (append (reverse (string->list "'\\''")) acc))]
        [else (loop (cdr cs) (cons (car cs) acc))])))

  (define (request-for buffer) (eq-hashtable-ref requests buffer #f))

  (define (take-request! buffer)
    (let ([r (request-for buffer)])
      (eq-hashtable-delete! requests buffer)
      r))

  (define (canceled-wrapper? wrapper) (eq-hashtable-ref canceled-wrappers wrapper #f))

  (define (answer! request answer)
    (when (string=? answer "cancel")
      (eq-hashtable-set! canceled-wrappers (request-wrapper request) #t))
    (let ([folder (request-folder request)])
      (and (file-directory? folder)
           (guard (c [(i/o-error? c) #f])
             (let ([temporary (string-append folder "/answer.tmp")])
               (call-with-port (open-file-output-port temporary (file-options no-fail))
                 (lambda (p) (put-bytevector p (string->utf8 (string-append answer "\n")))))
               (rename-file temporary (string-append folder "/answer"))
               #t)))))

  (define (read-request folder)
    (call-with-input-file (string-append folder "/request")
      (lambda (p)
        (let* ([directory (get-line p)] [file (get-line p)])
          (values directory file)))))

  (define (resolved directory file)
    (if (and (fx> (string-length file) 0) (char=? (string-ref file 0) #\/))
        file
        (string-append directory (if (and (fx> (string-length directory) 0)
                                          (char=? (string-ref directory (fx- (string-length directory) 1)) #\/))
                                     "" "/")
                       file)))

  ;; The message comes before the visit, so a message the visited
  ;; buffer's mode hooks say replaces it.
  (define (serve! folder wrapper)
    (let-values ([(directory file) (read-request folder)])
      (let* ([path (resolved directory file)] [stale (files:buffer-visiting path)])
        (when stale
          (guard (c [(i/o-error? c) (void)]) (files:revert-from-file stale)))
        (ask:message "Type C-c C-c to finish, C-c C-k to cancel")
        (let ([b (files:visit path)])
          (eq-hashtable-set! requests b (make-request folder wrapper (or (files:path b) path)))
          (buffers:with-buffer b (options:set-local! mode #t))
          (layout:switch-to-buffer b)))))

  (define request-prefix (string->utf8 "\x1b;]7563;tuna-edit;"))

  ;; A request longer than this is no request of ours.
  (define longest-request 4096)

  (define (slice bv start end)
    (let ([out (make-bytevector (fx- end start))])
      (bytevector-copy! bv start out 0 (fx- end start))
      out))

  (define (joined a b)
    (if (fx= (bytevector-length a) 0)
        b
        (let ([out (make-bytevector (fx+ (bytevector-length a) (bytevector-length b)))])
          (bytevector-copy! a 0 out 0 (bytevector-length a))
          (bytevector-copy! b 0 out (bytevector-length a) (bytevector-length b))
          out)))

  (define (index-of bv byte from)
    (let loop ([i from])
      (cond
        [(fx= i (bytevector-length bv)) #f]
        [(fx= (bytevector-u8-ref bv i) byte) i]
        [else (loop (fx+ i 1))])))

  (define (prefix-at data i)
    (let ([n (bytevector-length data)] [m (bytevector-length request-prefix)])
      (let loop ([k 0])
        (cond
          [(fx= k m) 'whole]
          [(fx= (fx+ i k) n) 'cut]
          [(fx= (bytevector-u8-ref data (fx+ i k)) (bytevector-u8-ref request-prefix k)) (loop (fx+ k 1))]
          [else 'none]))))

  ;; A request split across pieces of output is held until whole; the
  ;; newline the script prints after it goes with it.
  (define (filtering receiver wrapper)
    (let ([held #vu8()] [skip-newline? #f])
      (lambda (bytes end)
        (cond
          [(eof-object? bytes)
           (when (fx> (bytevector-length held) 0)
             (let ([h held]) (set! held #vu8()) (receiver h end)))
           (receiver bytes end)]
          [else
           (let* ([data (joined held bytes)] [n (bytevector-length data)])
             (set! held #vu8())
             (let-values ([(out done) (open-bytevector-output-port)])
               (let loop ([i (if (and skip-newline? (fx> n 0) (fx= (bytevector-u8-ref data 0) 10)) 1 0)])
                 (set! skip-newline? #f)
                 (let ([escape (index-of data 27 i)])
                   (cond
                     [(not escape) (put-bytevector out data i (fx- n i))]
                     [else
                      (put-bytevector out data i (fx- escape i))
                      (case (prefix-at data escape)
                        [(cut) (set! held (slice data escape n))]
                        [(none) (put-u8 out 27) (loop (fx+ escape 1))]
                        [else
                         (let* ([start (fx+ escape (bytevector-length request-prefix))]
                                [bell (index-of data 7 start)])
                           (cond
                             [(and (not bell) (fx< (fx- n escape) longest-request))
                              (set! held (slice data escape n))]
                             [(not bell) (put-u8 out 27) (loop (fx+ escape 1))]
                             [else
                              (let* ([payload (utf8->string (slice data start bell))]
                                     [semicolon (let find ([k 0])
                                                  (cond
                                                    [(fx= k (string-length payload)) #f]
                                                    [(char=? (string-ref payload k) #\;) k]
                                                    [else (find (fx+ k 1))]))])
                                (cond
                                  [(and semicolon (string=? (substring payload 0 semicolon) edit-token))
                                   (let ([folder (substring payload (fx+ semicolon 1) (string-length payload))])
                                     (call-as-owner %self (lambda () (spawn-task (lambda (restore) (serve! folder wrapper))))))
                                   (cond
                                     [(fx= (fx+ bell 1) n) (set! skip-newline? #t)]
                                     [(fx= (bytevector-u8-ref data (fx+ bell 1)) 10) (loop (fx+ bell 2))]
                                     [else (loop (fx+ bell 1))])]
                                  [else
                                   (put-bytevector out data escape (fx- (fx+ bell 1) escape))
                                   (loop (fx+ bell 1))]))]))])])))
               (let ([passed (done)])
                 (when (fx> (bytevector-length passed) 0)
                   (receiver passed end)))))])))))

(import %internals)

(define (environment variable)
  (unless (and (string? variable) (fx> (string-length variable) 0))
    (assertion-violation 'with-editor:environment "not a variable name" variable))
  (list (cons variable (string-append "sh " (shell-quoted (script-path))))
        (cons "TUNA_EDIT_TOKEN" edit-token)
        (cons "TUNA_PID" (number->string tuna-pid))))

(define (output-wrapper)
  (letrec ([wrapper (lambda (receiver)
                      (unless (procedure? receiver)
                        (assertion-violation 'with-editor:output-wrapper "not a procedure" receiver))
                      (filtering receiver wrapper))])
    wrapper))

(define (canceled? wrapper)
  (unless (procedure? wrapper)
    (assertion-violation 'with-editor:canceled? "not a procedure" wrapper))
  (canceled-wrapper? wrapper))

(define (%waiting-buffer who)
  (let ([b (buffers:current)])
    (unless (and b (request-for b))
      (error who "no program waits for this buffer"))
    b))

(commands:define-command (finish [force (commands:prefix-argument)])
  "Saves the buffer and tells the program waiting for it to go on, then kills the buffer; with a prefix argument, without asking with-editor:finish-checks."
  (let ([b (%waiting-buffer 'with-editor:finish)])
    (when (or force (for-all (lambda (entry) (entry b)) (hooks:entries finish-checks)))
      (files:save-buffer b)
      (let ([request (request-for b)])
        (cond
          [(answer! request "done")
           (take-request! b)
           (buffers:kill! b)
           (finished (request-path request))]
          [else (ask:message "The program that asked for this file has ended")])))))

;; Unmarked before it is killed, so files does not ask about the edits
;; the cancel throws away.
(commands:define-command (cancel [force (commands:prefix-argument)])
  "Tells the program waiting for the buffer to give up, and kills the buffer without saving; with a prefix argument, without asking with-editor:cancel-checks."
  (let ([b (%waiting-buffer 'with-editor:cancel)])
    (when (or force (for-all (lambda (entry) (entry b)) (hooks:entries cancel-checks)))
      (let ([request (take-request! b)])
        (answer! request "cancel")
        (buffers:set-modified! b #f)
        (buffers:kill! b)
        (canceled (request-path request))))))

(define (%cancel-killed buffer)
  (let ([request (take-request! buffer)])
    (when request
      (answer! request "cancel")
      (canceled (request-path request)))))

(keys:bind! keymap "C-c C-c" finish)
(keys:bind! keymap "C-c C-k" cancel)
(hooks:add! buffers:killed %cancel-killed)

(write-script!)

;; A program waiting from before a reload of this plugin still waits, so
;; its buffer takes this copy's mode and keys.
(vector-for-each
  (lambda (b) (when (buffers:live? b) (buffers:with-buffer b (options:set-local! mode #t))))
  (hashtable-keys requests))
