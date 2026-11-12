#!tuna
(import (buffers) (document) (jobs) (commands) (keys) (layout) (views) (files disk))

(define-option require-final-newline #f boolean?
  "When true, saving a file buffer whose text does not end in a line break adds one, as an edit.")

(define-hook after-visit
  "Called with a buffer after it has visited a file, before files:visit returns.")

(define-hook before-save
  "Called with a buffer before it is written; an entry may edit it.")

(define-hook after-save
  "Called with a buffer after its file has been written.")

(define-hook after-revert
  "Called with a buffer after its file has been read into it again.")

(define (%visit? v)
  (define (count? n) (and (fixnum? n) (fx>= n 0)))
  (and (vector? v) (fx= (vector-length v) 8)
       (string? (vector-ref v 0)) (string? (vector-ref v 1)) (string? (vector-ref v 2))
       (count? (vector-ref v 3)) (count? (vector-ref v 4))
       (boolean? (vector-ref v 5)) (boolean? (vector-ref v 6))
       (or (not (vector-ref v 7)) (count? (vector-ref v 7)))))

(define-saved %visits '() (lambda (v) (and (list? v) (for-all %visit? v))))

;; The process id and the command line handled, so a reload in the same
;; process opens nothing again.
(define-saved %arguments '() list?)

(define-condition-type &changed-on-disk &error %make-changed-on-disk %changed-on-disk?)

;; A job's raise would go to report as well as to the task waiting for
;; it, so a worker hands back its failure as data.
(jobs:define-worker (%reader path emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (read-file path))))

(jobs:define-worker (%reverter input emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (revert-file (car input) (cdr input)))))

(jobs:define-worker (%writer input emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (apply save-file input))))

(module %internals
  (check-main-thread check-buffer check-path check-task file-entry entry-of entry-path entry-length entry-hash
   entry-modified? entry-live? visited-buffers buffer-at open-buffer! remember-read! take-read!
   move-entry! with-entry-lock run-job record-read! mark-unmodified! save! forget-killed! take-back!
   open-pending! arguments-handled? handle-arguments! save-visits! stop-waiting!)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define (check-buffer who b)
    (unless (buffers:buffer? b)
      (assertion-violation who "not a buffer" b))
    (check-main-thread who))

  (define (check-path who path)
    (unless (string? path)
      (assertion-violation who "not a string" path))
    (check-main-thread who))

  (define (check-task who)
    (unless (current-task)
      (assertion-violation who "not in a task")))

  (define-record-type entry
    (sealed #t)
    (fields buffer (mutable path) (mutable given-name) (mutable length) (mutable hash)
            (mutable bom) (mutable crlf) (mutable saved-version) (mutable holder) (mutable job)
            (mutable waiters)))

  (define by-buffer (make-eq-hashtable))
  (define by-path (make-hashtable string-hash string=?))
  (define visited '())
  (define pending '())
  ;; Keyed by the reading task, so concurrent visits of one file keep
  ;; their reads apart; weak, so a read no visit takes is dropped with its
  ;; task.
  (define last-reads (make-weak-eq-hashtable))

  (define (entry-of b) (eq-hashtable-ref by-buffer b #f))

  (define (file-entry who b)
    (check-buffer who b)
    (or (entry-of b) (assertion-violation who "the buffer visits no file" b)))

  (define (entry-live? e) (eq? (entry-of (entry-buffer e)) e))

  (define (entry-modified? e)
    (not (eqv? (entry-saved-version e) (buffers:version (entry-buffer e)))))

  (define (visited-buffers) (reverse (map entry-buffer visited)))

  (define (buffer-at path)
    (let ([e (hashtable-ref by-path path #f)])
      (and e (entry-buffer e))))

  (define (entry->visit e)
    (vector (entry-path e) (buffers:name (entry-buffer e)) (entry-given-name e) (entry-length e)
            (entry-hash e) (entry-bom e) (entry-crlf e) (entry-saved-version e)))

  (define (visit->entry b v)
    (make-entry b (vector-ref v 0) (vector-ref v 2) (vector-ref v 3) (vector-ref v 4)
                (vector-ref v 5) (vector-ref v 6) (vector-ref v 7) #f #f '()))

  (define (visit-path v) (vector-ref v 0))
  (define (visit-name v) (vector-ref v 1))

  (define (save-visits!)
    (set-saved! %visits (append (map entry->visit (reverse visited)) pending)))

  (define (add-entry! e)
    (eq-hashtable-set! by-buffer (entry-buffer e) e)
    (hashtable-set! by-path (entry-path e) e)
    (set! visited (cons e visited)))

  (define (folder-names folder)
    (let loop ([chars (string->list folder)] [part '()] [parts '()])
      (define (close) (if (null? part) parts (cons (list->string (reverse part)) parts)))
      (cond
        [(null? chars) (reverse (close))]
        [(char=? (car chars) #\/) (loop (cdr chars) '() (close))]
        [else (loop (cdr chars) (cons (car chars) part) parts)])))

  (define (name-at path k)
    (let ([base (path-last path)])
      (if (fx= k 0)
          base
          (let* ([folder (path-parent path)] [parts (folder-names folder)] [n (length parts)])
            (string-append base "<"
              (if (fx> k n)
                  folder
                  (fold-left (lambda (s part) (if (string=? s "") part (string-append s "/" part)))
                             "" (list-tail parts (fx- n k))))
              ">")))))

  (define (distinct? names)
    (let ([seen (make-hashtable string-hash string=?)])
      (for-all (lambda (name)
                 (and (not (hashtable-contains? seen name))
                      (begin (hashtable-set! seen name #t) #t)))
               names)))

  (define (free-name name taken?)
    (if (taken? name)
        (let loop ([n 2])
          (let ([candidate (format "~a<~a>" name n)])
            (if (taken? candidate) (loop (fx+ n 1)) candidate)))
        name))

  (define (group-names paths taken?)
    (let ([top (fx+ 1 (apply fxmax 0 (map (lambda (p) (length (folder-names (path-parent p)))) paths)))])
      (let loop ([k (if (null? (cdr paths)) 0 1)])
        (let ([names (map (lambda (p) (name-at p k)) paths)])
          (cond
            [(and (distinct? names) (not (exists taken? names))) names]
            [(fx>= k top) (map (lambda (name) (free-name name taken?)) names)]
            [else (loop (fx+ k 1))])))))

  ;; A buffer the user renamed keeps its name.
  (define (group base)
    (filter (lambda (e)
              (and (string=? (path-last (entry-path e)) base)
                   (string=? (buffers:name (entry-buffer e)) (entry-given-name e))))
            (reverse visited)))

  (define (taken-by-others members)
    (let ([mine (map entry-buffer members)])
      (lambda (name)
        (let ([b (buffers:find name)])
          (and b (not (memq b mine)))))))

  ;; Renaming one buffer to the name another is about to leave would
  ;; clash, so when any new name is held, every buffer first moves aside.
  (define (rename-members! members names)
    (let ([changes (filter (lambda (c) (not (string=? (buffers:name (entry-buffer (car c))) (cdr c))))
                           (map cons members names))])
      (when (exists (lambda (c) (buffers:find (cdr c))) changes)
        (for-each (lambda (c) (buffers:rename! (entry-buffer (car c)) (string-append (cdr c) "\x0;")))
                  changes))
      (for-each (lambda (c)
                  (buffers:rename! (entry-buffer (car c)) (cdr c))
                  (entry-given-name-set! (car c) (cdr c)))
                changes)))

  (define (rename-group! base)
    (let ([members (group base)])
      (unless (null? members)
        (rename-members! members (group-names (map entry-path members) (taken-by-others members))))))

  (define (name-for! path)
    (let* ([members (group (path-last path))]
           [names (group-names (append (map entry-path members) (list path)) (taken-by-others members))])
      (rename-members! members (list-head names (length members)))
      (list-ref names (length members))))

  (define (remember-read! read) (eq-hashtable-set! last-reads (current-task) read))

  (define (take-read!)
    (let ([read (eq-hashtable-ref last-reads (current-task) #f)])
      (eq-hashtable-delete! last-reads (current-task))
      read))

  ;; Tuna's dynamic-wind holds quits off while its in runs, so bookkeeping
  ;; done there is never left half done.
  (define (without-quits thunk)
    (let ([result #f])
      (dynamic-wind (lambda () (set! result (thunk))) void void)
      result))

  ;; A document other than the one read carries edits made on the way,
  ;; so the buffer starts modified.
  (define (open-buffer! path doc length hash read)
    (without-quits
      (lambda ()
        (let* ([b (buffers:make (name-for! path) doc)]
               [e (make-entry b path (buffers:name b) length hash
                    (and read (contents-bom? read)) (and read (contents-crlf? read))
                    (and read (eq? doc (contents-document read)) (buffers:version b)) #f #f '())])
          (add-entry! e)
          (set! pending (filter (lambda (v) (not (string=? (visit-path v) path))) pending))
          (save-visits!)
          b))))

  (define (forget-entry! e)
    (without-quits
      (lambda ()
        (eq-hashtable-delete! by-buffer (entry-buffer e))
        (hashtable-delete! by-path (entry-path e))
        (set! visited (remq e visited))
        (rename-group! (path-last (entry-path e)))
        (save-visits!))))

  (define (move-entry! b path)
    (without-quits
      (lambda ()
        (let ([e (entry-of b)])
          (if e
              (let ([old (entry-path e)])
                (hashtable-delete! by-path old)
                (entry-path-set! e path)
                (set! visited (remq e visited))
                (let ([name (name-for! path)])
                  (buffers:rename! b name)
                  (entry-given-name-set! e name))
                (set! visited (cons e visited))
                (hashtable-set! by-path path e)
                (rename-group! (path-last old))
                (save-visits!)
                e)
              (let ([name (name-for! path)])
                (buffers:rename! b name)
                (let ([e (make-entry b path name 0 fnv-basis #f #f #f #f #f '())])
                  (add-entry! e)
                  (save-visits!)
                  e)))))))

  (define (record-save! e version result)
    (when (and (entry-live? e) (pair? result) (number? (car result)))
      (without-quits
        (lambda ()
          (entry-length-set! e (car result))
          (entry-hash-set! e (cadr result))
          (entry-saved-version-set! e version)
          (save-visits!)))))

  ;; Recorded before the edit, so a quit between them leaves the buffer
  ;; modified against the file now on disk rather than against the old one.
  (define (record-read! e read)
    (without-quits
      (lambda ()
        (entry-length-set! e (contents-length read))
        (entry-hash-set! e (contents-hash read))
        (entry-bom-set! e (contents-bom? read))
        (entry-crlf-set! e (contents-crlf? read)))))

  (define (mark-unmodified! e)
    (without-quits
      (lambda ()
        (entry-saved-version-set! e (buffers:version (entry-buffer e)))
        (save-visits!))))

  (define (changed-on-disk who path)
    (condition (%make-changed-on-disk) (make-who-condition who)
               (make-message-condition "another program changed the file") (make-irritants-condition (list path))))

  (define (add-final-newline! b)
    (let* ([doc (buffers:document b)] [n (document:length doc)])
      (when (and (fx> n 2) (not (eqv? (document:token doc (fx- n 2)) #\newline)))
        (buffers:replace! b (fx- n 1) (fx- n 1) "\n"))))

  ;; Unloading this module stops its jobs without ending them, and the
  ;; core stops only this module's own tasks, so it resumes these itself.
  ;; Whoever takes a waiter out of this list resumes it, so none is
  ;; resumed twice.
  (define waiting '())

  (define (take-waiter! w)
    (and (memq w waiting)
         (begin (set! waiting (remq w waiting)) #t)))

  (define (wake-waiters! e)
    (let ([waiters (entry-waiters e)])
      (entry-waiters-set! e '())
      (for-each (lambda (w) (when (take-waiter! w) ((cdr w) void))) waiters)))

  ;; A task that holds the lock, or a job still writing the file, makes
  ;; others wait. Tuna's dynamic-wind runs its out at each pause as well as
  ;; at the end, so the lock goes only once the body has returned or a
  ;; raise is leaving it; the in and out hold quits off. Two handlers note
  ;; the raise: a quit landing in the inner one as it starts reaches the
  ;; outer, and quits come a thousand calls apart.
  (define (with-entry-lock who e thunk)
    (let ([me (current-task)])
      (if (and me (eq? (entry-holder e) me))
          (thunk)
          (let ([entered #f] [leaving #f])
            (define (note c)
              (set! leaving #t)
              (let ([v (raise-continuable c)])
                (set! leaving #f)
                v))
            (let wait ()
              (when (or (entry-holder e) (entry-job e))
                (suspend
                  (lambda (resume)
                    (without-quits
                      (lambda ()
                        (let ([w (cons who resume)])
                          (set! waiting (cons w waiting))
                          (entry-waiters-set! e (cons w (entry-waiters e))))))))
                (wait)))
            (dynamic-wind
              (lambda ()
                (entry-holder-set! e me)
                (unless entered
                  (set! entered #t)
                  (set! leaving #t)))
              (lambda ()
                (with-exception-handler note
                  (lambda ()
                    (with-exception-handler note
                      (lambda ()
                        (set! leaving #f)
                        (call-with-values thunk
                          (lambda results (set! leaving #t) (apply values results))))))))
              (lambda ()
                (when (and leaving (eq? (entry-holder e) me))
                  (entry-holder-set! e #f)
                  (wake-waiters! e))))))))

  (define (stop-waiting!)
    (let ([stopped waiting])
      (set! waiting '())
      (for-each (lambda (w)
                  ((cdr w)
                   (lambda ()
                     (raise (condition (make-error) (make-who-condition (car w))
                                       (make-message-condition "the files plugin was unloaded"))))))
                stopped)))

  (define (failed result who)
    (and (failure? result)
         (raise (condition (if (failure-violation? result) (make-assertion-violation) (make-i/o-error))
                           (make-who-condition who) (make-message-condition (failure-message result))
                           (make-irritants-condition (failure-irritants result))))))

  ;; The job is this module's, so it outlives a reload of the caller's
  ;; module. Its result is recorded as it arrives, so a save is known even
  ;; when the waiting task has been signalled; and the entry stays busy
  ;; until the job ends, so another save cannot read the file mid-write.
  ;; The job, its waiter and the mark start with quits held off, so none
  ;; is left without the others.
  (define (run-job who worker input record! e)
    (let ([result #f])
      (suspend
        (lambda (resume)
          (let ([w (cons who resume)])
            (without-quits
              (lambda ()
                (as-module (this-module)
                  (jobs:start worker input
                    (lambda (v) (set! result v) (record! v))
                    (lambda (ended)
                      (when e
                        (entry-job-set! e #f)
                        (wake-waiters! e))
                      (when (take-waiter! w)
                        (resume
                          (lambda ()
                            (cond
                              [(condition? ended) (raise ended)]
                              [ended (assertion-violation who "the job was stopped")])
                            (failed result who)
                            result))))))
                (set! waiting (cons w waiting))
                (when e (entry-job-set! e #t)))))))))

  (define (save! who e check?)
    (let ([b (entry-buffer e)])
      (buffers:with-buffer b (before-save b))
      (when (and (entry-live? e) (buffers:with-buffer b (require-final-newline)))
        (add-final-newline! b))
      (when (entry-live? e)
        (let* ([version (buffers:version b)]
               [result (run-job who %writer
                         (list (entry-path e) (buffers:document b) (entry-bom e) (entry-crlf e)
                               (entry-length e) (entry-hash e) check?)
                         (lambda (result) (record-save! e version result))
                         e)])
          (when (eq? result 'changed)
            (raise (changed-on-disk who (entry-path e))))
          (when (entry-live? e)
            (buffers:with-buffer b (after-save b)))))))

  (define (forget-killed! buffer)
    (let ([e (entry-of buffer)])
      (when e (forget-entry! e))))

  (define (take-back!)
    (for-each
      (lambda (v)
        (let ([b (buffers:find (visit-name v))])
          (if (and b (not (entry-of b)) (not (hashtable-ref by-path (visit-path v) #f)))
              (add-entry! (visit->entry b v))
              (set! pending (cons v pending)))))
      (%visits))
    (set! pending (reverse pending)))

  (define (open-pending! visit)
    (for-each (lambda (v)
                (guard (c [(not (quit-condition? c)) (report c)])
                  (visit (visit-path v)))
                (set! pending (remq v pending)))
              pending))

  (define (handled-arguments) (cons (get-process-id) (command-line-arguments)))

  (define (arguments-handled?) (equal? (%arguments) (handled-arguments)))

  (define (line-argument s)
    (and (fx> (string-length s) 1)
         (char=? (string-ref s 0) #\+)
         (for-all char-numeric? (cdr (string->list s)))
         (string->number (substring s 1 (string-length s)))))

  (define (flag? s)
    (and (fx>= (string-length s) 2) (char=? (string-ref s 0) #\-) (char=? (string-ref s 1) #\-)))

  (define (line-start doc line)
    (let ([last (document:line doc (document:length doc))])
      (fxmax 1 (document:line-start doc (fxmax 1 (fxmin line last))))))

  ;; Only the last file is shown, so a +N before another has no view to
  ;; move.
  (define (handle-arguments! visit)
    (let ([handled (handled-arguments)])
      (let loop ([arguments (cdr handled)] [line #f] [shown #f])
        (cond
          [(null? arguments)
           (when shown
             (let ([b (car shown)] [line (cdr shown)])
               (layout:switch-to-buffer b)
               (when line
                 (views:set-point! (layout:selected-view) (line-start (buffers:document b) line)))))]
          [(flag? (car arguments)) (loop (cdr arguments) line shown)]
          [(line-argument (car arguments)) => (lambda (n) (loop (cdr arguments) n shown))]
          [else
           (let ([b (guard (c [(not (quit-condition? c)) (report c) #f])
                      (visit (car arguments)))])
             (loop (cdr arguments) #f (if b (cons b line) shown)))]))
      (set-saved! %arguments handled))))

(import %internals)

(define (read-document path)
  (check-path 'files:read-document path)
  (check-task 'files:read-document)
  (let ([read (run-job 'files:read-document %reader (true-path path) (lambda (read) (void)) #f)])
    (remember-read! read)
    (values (contents-document read) (contents-length read) (contents-hash read))))

(define (visit path)
  (check-path 'files:visit path)
  (let ([path (true-path path)])
    (or (buffer-at path)
        (let-values ([(doc length hash) (read-document path)])
          (let ([read (take-read!)])
            (or (buffer-at path)
                (let ([b (open-buffer! path doc length hash read)])
                  (buffers:with-buffer b (after-visit b))
                  b)))))))

(commands:define-command (find-file path)
  "Visits PATH and shows its buffer in the selected view."
  (layout:switch-to-buffer (visit path)))

(define (path buffer)
  (check-buffer 'files:path buffer)
  (let ([e (entry-of buffer)])
    (and e (entry-path e))))

(define (buffer-visiting path)
  (check-path 'files:buffer-visiting path)
  (buffer-at (true-path path)))

(define (buffers)
  (check-main-thread 'files:buffers)
  (visited-buffers))

(commands:define-command (save-buffer [buffer (buffers:current)])
  "Saves BUFFER to its file when it is modified."
  (let ([e (file-entry 'files:save-buffer buffer)])
    (check-task 'files:save-buffer)
    (with-entry-lock 'files:save-buffer e
      (lambda ()
        (when (and (entry-live? e) (entry-modified? e))
          (save! 'files:save-buffer e #t))))))

(commands:define-command (write-file path [buffer (buffers:current)])
  "Makes BUFFER visit PATH, renaming it after the file, and saves it there."
  (check-path 'files:write-file path)
  (check-buffer 'files:write-file buffer)
  (check-task 'files:write-file)
  (let* ([path (true-path path)] [other (buffer-at path)])
    (when (and other (not (eq? other buffer)))
      (assertion-violation 'files:write-file "another buffer visits the file" path))
    (let ([e (move-entry! buffer path)])
      (with-entry-lock 'files:write-file e
        (lambda ()
          (when (entry-live? e)
            (save! 'files:write-file e #f)))))))

(commands:define-command (revert-buffer [buffer (buffers:current)])
  "Reads BUFFER's file again and replaces the part of the text that differs, as one edit."
  (let ([e (file-entry 'files:revert-buffer buffer)])
    (check-task 'files:revert-buffer)
    (with-entry-lock 'files:revert-buffer e
      (lambda ()
        (let retry ([tries 0])
          (let* ([version (buffers:version buffer)]
                 [old (buffers:document buffer)]
                 [read (run-job 'files:revert-buffer %reverter (cons (entry-path e) old) (lambda (read) (void)) e)])
            (cond
              [(not (entry-live? e)) (void)]
              [(and (not (= version (buffers:version buffer))) (fx< tries 2)) (retry (fx+ tries 1))]
              [else
               (let ([new (contents-document (car read))])
                 (record-read! e (car read))
                 (if (= version (buffers:version buffer))
                     (apply (lambda (start end new-start new-end)
                              (unless (and (= start end) (= new-start new-end))
                                (buffers:replace! buffer start end (document:slice new new-start new-end))))
                            (cdr read))
                     (buffers:replace! buffer 1 (fx- (document:length (buffers:document buffer)) 1)
                       (document:slice new 1 (fx- (document:length new) 1))))
                 (mark-unmodified! e)
                 (buffers:with-buffer buffer (after-revert buffer)))])))))))

(commands:define-command (not-modified [buffer (buffers:current)])
  "Marks BUFFER unmodified, as a save does, without writing."
  (check-buffer 'files:not-modified buffer)
  (let ([e (entry-of buffer)])
    (when e (mark-unmodified! e))))

(commands:define-command (save-buffers-kill-tuna)
  "Exits Tuna without asking: undo restores unsaved edits at the next visit."
  (exit))

(define (modified? buffer)
  (check-buffer 'files:modified? buffer)
  (let ([e (entry-of buffer)])
    (and e (entry-modified? e))))

(define (fingerprint buffer)
  (let ([e (file-entry 'files:fingerprint buffer)])
    (values (entry-length e) (entry-hash e))))

(define (changed-on-disk-condition? v)
  (%changed-on-disk? v))

(add-hook! buffers:killed forget-killed!)
(keys:bind! keys:global "C-x C-s" save-buffer)
(keys:bind! keys:global "M-~" not-modified)
(keys:bind! keys:global "C-x C-c" save-buffers-kill-tuna)
(on-unload save-visits!)
(on-unload stop-waiting!)
(take-back!)
(spawn-task
  (lambda ()
    (open-pending! visit)
    (unless (arguments-handled?)
      (handle-arguments! visit))))
