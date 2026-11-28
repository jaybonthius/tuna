#!tuna
(import (buffers) (document) (jobs) (commands) (keys) (ask) (files disk) (files paths) (hooks) (options) (tables) (saved))

(define %self (current-owner))

(options:define-option require-final-newline #f boolean?
  "When true, saving a file buffer whose text does not end in a line break adds one, as an edit.")

(options:define-option confirm-exit? #f boolean?
  "When true, files:save-buffers-kill-tuna asks before it exits, unless it has asked about modified buffers.")

(hooks:define-hook after-visit
  "Called with a buffer after it has visited a file, before files:visit returns.")

(hooks:define-hook after-temporary-visit
  "Called with a buffer after it has visited a file temporarily, before files:visit-temporarily returns, in place of files:after-visit: the work a temporary visit allows.")

(hooks:define-hook before-save
  "Called with a buffer before it is written; an entry may edit it.")

(hooks:define-hook after-save
  "Called with a buffer after its file has been written.")

(hooks:define-hook after-revert
  "Called with a buffer after its file has been read into it again.")

(hooks:define-hook unsaved-kept
  "Called with a modified buffer when Tuna is asked to exit or to kill the buffer; an entry that returns true keeps the buffer's unsaved edits, so neither asks about it.")

(hooks:define-hook folder-visitors
  "Called with a folder's resolved path when files:visit finds a folder; the first entry, by depth, that returns a buffer gives files:visit its result.")

(hooks:define-hook after-rename
  "Called with the old and new paths after files:rename-file has renamed a file or folder and moved the buffers visiting it.")

(hooks:define-hook visited-path-changed
  "Called with a buffer, the path it visited or #f, and the path it visits after it has started visiting another file, by files:write-file or files:rename-file; before the write that may follow.")

(hooks:define-hook directory-finders
  "Called with a buffer by files:directory; the first entry, by depth, that returns a folder, a string starting with /, gives the buffer's folder. files' own entry, files:file-directory, is at depth -10.")

(define (%absolute-folder? v)
  (and (string? v) (fx> (string-length v) 0) (char=? (string-ref v 0) #\/)))

(options:define-option directory-override #f
  (lambda (v)
    (or (not v)
        (and (pair? v) (buffers:buffer? (car v)) (%absolute-folder? (cdr v)))))
  "#f, or a pair of a buffer and a folder starting with /, which files:directory of that buffer returns; a command binds it with options:with for the commands it runs.")

(define (%within? path folder)
  (let ([n (string-length folder)])
    (and (fx>= (string-length path) n) (string=? (substring path 0 n) folder)
         (or (fx= (string-length path) n) (char=? (string-ref path n) #\/)))))

(define (renamed-path path from to)
  (for-each (lambda (x) (unless (string? x) (assertion-violation 'files:renamed-path "not a string" x)))
            (list path from to))
  (and (%within? path from)
       (string-append to (substring path (string-length from) (string-length path)))))

(define (%without-final-slash folder)
  (let ([n (string-length folder)])
    (if (and (fx> n 1) (char=? (string-ref folder (fx- n 1)) #\/))
        (substring folder 0 (fx- n 1))
        folder)))

;; Files are named by their true paths, so the home folder is matched as
;; HOME gives it and resolved through symbolic links too. A home of / is
;; left alone, as Emacs leaves it, since every path would start with ~.
(define (%home-forms home)
  (let ([given (and home (%without-final-slash home))])
    (if (and given (fx> (string-length given) 1))
        (let ([true (true-path given)])
          (if (or (string=? true given) (fx<= (string-length true) 1)) (list given) (list given true)))
        '())))

;; Resolving the home folder reads the disk, so it is done once for each
;; value of HOME.
(define %home-folders-of #f)

(define (%home-folders)
  (let ([home (getenv "HOME")])
    (unless (and %home-folders-of (equal? (car %home-folders-of) home))
      (set! %home-folders-of (cons home (%home-forms home))))
    (cdr %home-folders-of)))

(define (abbreviated-path path)
  (unless (string? path)
    (assertion-violation 'files:abbreviated-path "not a string" path))
  (let ([home (find (lambda (home) (%within? path home)) (%home-folders))])
    (if home
        (string-append "~" (substring path (string-length home) (string-length path)))
        path)))

;; The disk is not read, as Emacs's expand-file-name does not read it, so
;; a .. after a symbolic link leaves the link's text, not its target. A
;; ~user path raises: the user database may wait on a network, and only
;; processes looks a user up, off the main thread.
(define expanded-path
  (case-lambda
    [(path) (expanded-path path (current-directory))]
    [(path folder)
     (unless (string? path)
       (assertion-violation 'files:expanded-path "not a string" path))
     (unless (%absolute-folder? folder)
       (assertion-violation 'files:expanded-path "not a folder starting with /" folder))
     (let* ([n (string-length path)]
            [whole (cond
                     [(and (fx> n 0) (char=? (string-ref path 0) #\/)) path]
                     [(and (fx> n 0) (char=? (string-ref path 0) #\~))
                      (unless (or (fx= n 1) (char=? (string-ref path 1) #\/))
                        (assertion-violation 'files:expanded-path "a path starting with ~user" path))
                      (let ([home (getenv "HOME")])
                        (if (fx= n 1) (or home "/") (string-append (or home "") (substring path 1 n))))]
                     [else (string-append folder "/" path)])]
            [parts (fold-left
                     (lambda (kept part)
                       (cond
                         [(or (string=? part "") (string=? part ".")) kept]
                         [(string=? part "..") (if (null? kept) kept (cdr kept))]
                         [else (cons part kept)]))
                     '() (%split-path whole))]
            [joined (fold-left (lambda (rest part) (string-append "/" part rest)) "" parts)])
       (cond
         [(string=? joined "") "/"]
         [(char=? (string-ref whole (fx- (string-length whole) 1)) #\/) (string-append joined "/")]
         [else joined]))]))

(define (%split-path path)
  (let loop ([i (fx- (string-length path) 1)] [end (string-length path)] [parts '()])
    (cond
      [(fx< i 0) (cons (substring path 0 end) parts)]
      [(char=? (string-ref path i) #\/) (loop (fx- i 1) i (cons (substring path (fx+ i 1) end) parts))]
      [else (loop (fx- i 1) end parts)])))

(options:define-option offer-save? #t boolean?
  "When false in a buffer that visits no file, the buffer holds nothing to save: killing it asks nothing, and files:save-buffer leaves it alone.")

(options:define-option delete-by-moving-to-trash? #f boolean?
  "When true, commands that delete files for the user move them to the trash with files:move-to-trash.")

(define (%visit? v)
  (define (count? n) (and (fixnum? n) (fx>= n 0)))
  (and (vector? v) (fx= (vector-length v) 7)
       (string? (vector-ref v 0)) (string? (vector-ref v 1)) (string? (vector-ref v 2))
       (count? (vector-ref v 3)) (count? (vector-ref v 4))
       (boolean? (vector-ref v 5)) (boolean? (vector-ref v 6))))

(saved:define-saved %visits '() (lambda (v) (and (list? v) (for-all %visit? v))))

(define-condition-type &canceled &error %make-canceled %canceled?)

(define-condition-type %&folder &i/o-filename %make-folder %folder?)

;; A job's raise would go to report as well as to the task waiting for
;; it, so a worker hands back its failure as data.
(jobs:define-worker (%reader path emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (if (file-directory? path) 'folder (read-file path)))))

(jobs:define-worker (%reverter input emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (revert-file (car input) (cdr input)))))

(jobs:define-worker (%folder-maker folder emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (make-folders folder))))

(jobs:define-worker (%writer input emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (apply save-file input))))

(jobs:define-worker (%renamer input emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (apply rename-path (append input (list (lambda () (emit 'moved))))))))

(jobs:define-worker (%copier input emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (apply copy-path input))))

(jobs:define-worker (%deleter path emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (delete-path path))))

(jobs:define-worker (%trasher path emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (trash-path path))))

(jobs:define-worker (%folder-creator path emit)
  (import (files disk))
  (emit (guard (c [#t (failure c)]) (make-new-folder path))))

;; A file that cannot be read counts as unchanged, so its buffer is left
;; as a gone file's is.
(jobs:define-worker (%fingerprinter paths emit)
  (import (files disk))
  (emit (map (lambda (path) (guard (c [#t #f]) (disk-fingerprint path))) paths)))

(jobs:define-worker (%unreadable-finder paths emit)
  (import (files disk))
  (emit (filter (lambda (path) (not (readable? path))) paths)))

(module %internals
  (check-main-thread check-buffer check-path check-task file-entry entry-of entry-path entry-length entry-hash
   entry-left-alone entry-left-alone-set!
   entry-live? visited-buffers buffer-at open-buffer! remember-read! take-read!
   move-entry! move-entries-under! check-not-visited-under with-entry-lock run-job run-operation record-read! save! forget-killed!
   take-back! open-pending! save-visits! stop-waiting! mark-temporary! end-temporary! temporary-buffer?)

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
            (mutable bom) (mutable crlf) (mutable holder) (mutable job) (mutable waiters) (mutable left-alone)))

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

  (define (visited-buffers) (reverse (map entry-buffer visited)))

  (define (buffer-at path)
    (let ([e (hashtable-ref by-path path #f)])
      (and e (entry-buffer e))))

  (define (entry->visit e)
    (vector (entry-path e) (buffers:name (entry-buffer e)) (entry-given-name e) (entry-length e)
            (entry-hash e) (entry-bom e) (entry-crlf e)))

  (define (visit->entry b v)
    (make-entry b (vector-ref v 0) (vector-ref v 2) (vector-ref v 3) (vector-ref v 4)
                (vector-ref v 5) (vector-ref v 6) #f #f '() #f))

  (define (visit-path v) (vector-ref v 0))
  (define (visit-name v) (vector-ref v 1))

  ;; A temporary visit is no visit a restart should open again.
  (define temporary (make-weak-eq-hashtable))

  (define (mark-temporary! b)
    (eq-hashtable-set! temporary b #t)
    (save-visits!))

  (define (end-temporary! b)
    (and (eq-hashtable-ref temporary b #f)
         (begin
           (eq-hashtable-delete! temporary b)
           (save-visits!)
           #t)))

  (define (temporary-buffer? b) (eq-hashtable-ref temporary b #f))

  (define (save-visits!)
    (saved:set! %visits (append (map entry->visit (reverse (remp (lambda (e) (temporary-buffer? (entry-buffer e))) visited)))
                                pending)))

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
    (let ([base (let ([last (path-last path)])
                  (if (buffers:internal-name? last) (string-append "|" last) last))])
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

  ;; Tuna's dynamic-wind holds cancels off while its in runs, so bookkeeping
  ;; done there is never left half done.
  (define (without-cancels thunk)
    (let ([result #f])
      (dynamic-wind (lambda () (set! result (thunk))) void void)
      result))

  ;; A document other than the one read carries edits made on the way,
  ;; so the buffer starts modified.
  (define (open-buffer! path doc length hash read)
    (without-cancels
      (lambda ()
        (let* ([b (buffers:make (name-for! path) doc)]
               [e (make-entry b path (buffers:name b) length hash
                    (and read (contents-bom? read)) (and read (contents-crlf? read)) #f #f '() #f)])
          (unless (and read (eq? doc (contents-document read)))
            (buffers:set-modified! b #t))
          (when (and read (contents-write-protected? read))
            (buffers:set-read-only! b #t))
          (add-entry! e)
          (set! pending (filter (lambda (v) (not (string=? (visit-path v) path))) pending))
          (save-visits!)
          b))))

  (define (forget-entry! e)
    (without-cancels
      (lambda ()
        (eq-hashtable-delete! by-buffer (entry-buffer e))
        (hashtable-delete! by-path (entry-path e))
        (set! visited (remq e visited))
        (rename-group! (path-last (entry-path e)))
        (save-visits!))))

  (define (move-entry! b path)
    (let* ([old (let ([e (entry-of b)]) (and e (entry-path e)))]
           [e (move-entry-quietly! b path)])
      (unless (equal? old path)
        (buffers:with-buffer b (visited-path-changed b old path)))
      e))

  ;; The buffer leaves its name first, so a file named as the buffer is
  ;; not given a name made distinct from the buffer's own.
  (define (move-entry-quietly! b path)
    (without-cancels
      (lambda ()
        (buffers:rename! b (string-append (buffers:name b) "\x0;"))
        (let ([e (entry-of b)])
          (if e
              (let ([old (entry-path e)])
                (hashtable-delete! by-path old)
                (entry-path-set! e path)
                (entry-left-alone-set! e #f)
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
                (let ([e (make-entry b path name 0 fnv-basis #f #f #f #f '() #f)])
                  (add-entry! e)
                  (save-visits!)
                  e)))))))

  ;; The hook is called as the save is recorded, not when the saving task
  ;; resumes, since a cancel can reach that task after the file is written.
  (define (record-save! e version result)
    (when (and (entry-live? e) (pair? result) (number? (car result)))
      (let ([b (entry-buffer e)])
        (without-cancels
          (lambda ()
            (entry-length-set! e (car result))
            (entry-hash-set! e (cadr result))
            (entry-left-alone-set! e #f)
            (when (= version (buffers:version b))
              (buffers:set-modified! b #f))
            (save-visits!)))
        (ask:message (string-append "Wrote " (abbreviated-path (entry-path e))))
        (buffers:with-buffer b (after-save b)))))

  ;; Recorded before the edit, so a cancel between them leaves the buffer
  ;; modified against the file now on disk rather than against the old one.
  (define (record-read! e read)
    (without-cancels
      (lambda ()
        (entry-length-set! e (contents-length read))
        (entry-hash-set! e (contents-hash read))
        (entry-left-alone-set! e #f)
        (entry-bom-set! e (contents-bom? read))
        (entry-crlf-set! e (contents-crlf? read)))))

  (define (add-final-newline! b)
    (let* ([doc (buffers:document b)] [n (document:length doc)])
      (when (and (fx> n 2) (not (buffers:read-only? b)) (not (eqv? (document:token doc (fx- n 2)) #\newline)))
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
  ;; raise is leaving it; the in and out hold cancels off. Two handlers note
  ;; the raise: a cancel landing in the inner one as it starts reaches the
  ;; outer, and cancels come a thousand calls apart.
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
                    (without-cancels
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
         (let ([irritants (map (lambda (x) (if (string? x) (abbreviated-path x) x)) (failure-irritants result))]
               [format? (failure-format? result)])
           (raise (condition (cond
                               [(failure-violation? result) (make-assertion-violation)]
                               [(failure-already-exists? result) (make-i/o-file-already-exists-error (failure-filename result))]
                               [(failure-filename result) => make-i/o-filename-error]
                               [else (make-i/o-error)])
                             (make-who-condition who)
                             (make-message-condition
                               (if format? (apply format (failure-message result) irritants) (failure-message result)))
                             (make-irritants-condition (if format? '() irritants)))))))

  ;; The job is this module's, so it outlives a reload of the caller's
  ;; module. Its result is recorded as it arrives, so a save is known even
  ;; when the waiting task has been signalled; and the entry stays busy
  ;; until the job ends, so another save cannot read the file mid-write.
  ;; The job, its waiter and the mark start with cancels held off, so none
  ;; is left without the others.
  (define (run-job who worker input record! e)
    (let ([result #f])
      (suspend
        (lambda (resume)
          (let ([w (cons who resume)])
            (without-cancels
              (lambda ()
                (call-as-owner %self
                  (lambda ()
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
                              result)))))))
                (set! waiting (cons w waiting))
                (when e (entry-job-set! e #t)))))))))

  ;; Unlike a save, an operation on files may run long, so a cancel of the
  ;; task waiting for it stops the job; the files already done stay done.
  ;; Each value is recorded as it arrives, as a save's is, since a cancel
  ;; can reach the task after the job has done its work but before the
  ;; task resumes.
  (define run-operation
    (case-lambda
      [(who worker input) (run-operation who worker input (lambda (v) (void)))]
      [(who worker input record!)
       (let ([job #f] [result #f])
         (guard (c [#t (when job (jobs:stop! job)) (raise c)])
           (suspend
             (lambda (resume)
               (let ([w (cons who resume)])
                 (without-cancels
                   (lambda ()
                     (call-as-owner %self
                       (lambda ()
                         (set! job
                           (jobs:start worker input
                             (lambda (v) (set! result v) (record! v))
                             (lambda (ended)
                               (when (take-waiter! w)
                                 (resume
                                   (lambda ()
                                     (cond
                                       [(condition? ended) (raise ended)]
                                       [ended (assertion-violation who "the job was stopped")])
                                     (failed result who)
                                     result))))))))
                     (set! waiting (cons w waiting)))))))))]))

  ;; Moving the renamed buffers onto a path another buffer visits would
  ;; leave two buffers on one file, so the rename is refused first, as
  ;; write-file refuses that file.
  (define (check-not-visited-under who from to)
    (for-each
      (lambda (e)
        (let ([path (entry-path e)])
          (when (and (%within? path to) (not (%within? path from)))
            (error who "another buffer visits the file" (abbreviated-path path)))))
      visited))

  (define (move-entries-under! from to)
    (for-each
      (lambda (e)
        (let ([path (renamed-path (entry-path e) from to)])
          (when path (move-entry! (entry-buffer e) path))))
      (reverse visited)))

  (define (save! who e)
    (let ([b (entry-buffer e)])
      (buffers:with-buffer b (before-save b))
      (when (and (entry-live? e) (buffers:with-buffer b (require-final-newline)))
        (add-final-newline! b))
      (when (entry-live? e)
        (let ([version (buffers:version b)])
          (run-job who %writer (list (entry-path e) (buffers:document b) (entry-bom e) (entry-crlf e))
            (lambda (result) (record-save! e version result))
            e)))))

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
                (guard (c [(not (cancelled? c)) (report c)])
                  (visit (visit-path v)))
                (set! pending (remq v pending)))
              pending)))

(import %internals)

(define (read-document path)
  (check-path 'files:read-document path)
  (check-task 'files:read-document)
  (let* ([path (true-path path)]
         [read (run-job 'files:read-document %reader path (lambda (read) (void)) #f)])
    (when (eq? read 'folder)
      (raise (condition (%make-folder path) (make-who-condition 'files:read-document)
                        (make-message-condition "is a folder") (make-irritants-condition (list (abbreviated-path path))))))
    (remember-read! read)
    (values (contents-document read) (contents-length read) (contents-hash read))))

(define (%visit-folder path c)
  (let ([b (exists (lambda (entry) (entry path)) (hooks:entries folder-visitors))])
    (unless b (raise c))
    (unless (buffers:buffer? b)
      (assertion-violation 'files:visit "a folder visitor returned no buffer" b))
    b))

(define (%completed b)
  (when (end-temporary! b)
    (buffers:with-buffer b (after-visit b)))
  b)

(define (visit path)
  (check-path 'files:visit path)
  (let ([path (true-path path)])
    (cond
      [(buffer-at path) => %completed]
      [else
       (guard (c [(%folder? c) (%visit-folder path c)])
         (let-values ([(doc length hash) (read-document path)])
           (let ([read (take-read!)])
             (cond
               [(buffer-at path) => %completed]
               [else
                (let ([b (open-buffer! path doc length hash read)])
                  (cond
                    [(and read (contents-missing? read))
                     (ask:message (cond
                                    [(contents-folder-missing? read)
                                     (format "(New file; folder ~a does not exist)" (abbreviated-path (path-parent path)))]
                                    [(contents-write-protected? read) "File not found and directory write-protected"]
                                    [else "(New file)"]))]
                    [(and read (contents-write-protected? read))
                     (ask:message "Note: file is write protected")])
                  (buffers:with-buffer b (after-visit b))
                  b)]))))])))

(define (visit-temporarily path)
  (check-path 'files:visit-temporarily path)
  (let ([path (true-path path)])
    (or (buffer-at path)
        (let-values ([(doc length hash) (read-document path)])
          (let ([read (take-read!)])
            (or (buffer-at path)
                (let ([b (open-buffer! path doc length hash read)])
                  (mark-temporary! b)
                  (buffers:with-buffer b (after-temporary-visit b))
                  b)))))))

(define (temporary? buffer)
  (check-buffer 'files:temporary? buffer)
  (and (temporary-buffer? buffer) #t))

(define (path buffer)
  (check-buffer 'files:path buffer)
  (let ([e (entry-of buffer)])
    (and e (entry-path e))))

;; A temporary buffer is no visit to anyone outside, so a report to its
;; file stays the file's until a visit completes it.
(define (buffer-visiting path)
  (check-path 'files:buffer-visiting path)
  (let ([b (buffer-at (true-path path))])
    (and b (not (temporary-buffer? b)) b)))

(define (buffers)
  (check-main-thread 'files:buffers)
  (visited-buffers))

(define (%with-final-slash folder)
  (let ([n (string-length folder)])
    (if (and (fx> n 0) (char=? (string-ref folder (fx- n 1)) #\/))
        folder
        (string-append folder "/"))))

(define (%home-folder) (%with-final-slash (or (getenv "HOME") "/")))

(define (file-directory buffer)
  (check-buffer 'files:file-directory buffer)
  (let ([e (entry-of buffer)])
    (and e (%with-final-slash (path-parent (entry-path e))))))

;; Commands hand the folder to projects:find, which walks it upward as
;; text and takes only an absolute one, so a finder's answer follows the
;; override's rule, and a wrong one is refused here, at its source.
(define (%found-directory buffer)
  (exists
    (lambda (entry)
      (let ([folder (entry buffer)])
        (unless (or (not folder) (%absolute-folder? folder))
          (assertion-violation 'files:directory "a directory finder returned no absolute folder" folder))
        (and folder (%with-final-slash folder))))
    (hooks:entries directory-finders)))

(define directory
  (case-lambda
    [() (let ([b (buffers:current)]) (if b (directory b) (%home-folder)))]
    [(buffer)
     (check-buffer 'files:directory buffer)
     (let ([override (directory-override)])
       (if (and override (eq? (car override) buffer))
           (%with-final-slash (cdr override))
           (or (%found-directory buffer) (%home-folder))))]))

(define (%cancel who path)
  (raise (condition (%make-canceled) (make-who-condition who)
                    (make-message-condition "canceled") (make-irritants-condition (list (abbreviated-path path))))))

(define (%confirm-overwrite who path)
  (when (and (file-exists? path) (not (ask:y-or-n? "File exists; overwrite? ")))
    (%cancel who path)))

(define (%confirm-save who path)
  (let ([folder (path-parent path)])
    (cond
      [(not (file-exists? folder))
       (unless (ask:y-or-n? (format "Folder ~a does not exist; create? " (abbreviated-path folder)))
         (%cancel who folder))
       (run-job who %folder-maker folder (lambda (made) (void)) #f)]
      [(and (file-exists? path) (not (writable? path))
            (not (ask:yes-or-no? "File is write-protected; try to save anyway? ")))
       (%cancel who path)])))

(define (%check-file-to-save who path buffer)
  (let ([other (buffer-at path)])
    (when (file-directory? path)
      (error who "is a folder" (abbreviated-path path)))
    (when (and other (not (eq? other buffer)))
      (error who "another buffer visits the file" (abbreviated-path path)))
    path))

(define (%ask-file-name who question buffer)
  (let ([path (ask:file-name question)])
    (check-path who path)
    (%check-file-to-save who (true-path path) buffer)))

(define (%file-in-folder path buffer)
  (let ([n (string-length path)])
    (if (or (and (fx> n 0) (char=? (string-ref path (fx- n 1)) #\/))
            (file-directory? (true-path path)))
        (string-append (%with-final-slash path)
                       (path-last (let ([e (entry-of buffer)]) (if e (entry-path e) (buffers:name buffer)))))
        path)))

(define (%read-file-to-write)
  (let ([buffer (buffers:current)] [path (ask:file-name "Write file: ")])
    (check-path 'files:write-file path)
    (let ([path (%check-file-to-save 'files:write-file (true-path (%file-in-folder path buffer)) buffer)])
      (unless (commands:prefix-argument)
        (%confirm-overwrite 'files:write-file path))
      (%confirm-save 'files:write-file path)
      path)))

;; Asked before before-save runs, as Emacs's basic-save-buffer asks, so an
;; entry that edits the buffer or asks a server runs only for a save that
;; will be made.
;; The file is read under the entry lock, so a save still writing it is
;; done and recorded first, and its write is no other program's change;
;; that save may also leave nothing to save.
(define (%confirm-changed-on-disk buffer e)
  (when (and (with-entry-lock 'files:save-buffer e
               (lambda ()
                 (and (entry-live? e) (buffers:modified? buffer)
                      (let ([on-disk (car (run-operation 'files:save-buffer %fingerprinter (list (entry-path e))))])
                        (and on-disk (not (equal? on-disk (list (entry-length e) (entry-hash e)))))))))
             (not (ask:yes-or-no? (format "~a changed on disk since it was read; save anyway? " (abbreviated-path (entry-path e))))))
    (%cancel 'files:save-buffer (entry-path e))))

(commands:define-command (save-buffer [buffer (buffers:current)])
  "Saves BUFFER to its file when it is modified, asking for a file when it visits none and files:offer-save? is true there."
  (check-buffer 'files:save-buffer buffer)
  (check-task 'files:save-buffer)
  (let ([e (entry-of buffer)])
    (cond
      [(or (not (buffers:modified? buffer)) (and (not e) (not (buffers:with-buffer buffer (offer-save?)))))
       (when (eq? (commands:this-command) save-buffer)
         (ask:message "(No changes need to be saved)"))]
      [e
       ;; Asked outside the entry lock, so other saves of the buffer do not
       ;; wait on the user.
       (%confirm-save 'files:save-buffer (entry-path e))
       (%confirm-changed-on-disk buffer e)
       (with-entry-lock 'files:save-buffer e
         (lambda ()
           (when (and (entry-live? e) (buffers:modified? buffer))
             (save! 'files:save-buffer e))))]
      [else
       (let ([path (%ask-file-name 'files:save-buffer "File to save in: " buffer)])
         (%confirm-overwrite 'files:save-buffer path)
         (%confirm-save 'files:save-buffer path)
         (write-file path buffer))])))

(commands:define-command (write-file [path (%read-file-to-write)] [buffer (buffers:current)])
  "Makes BUFFER visit PATH, renaming it after the file, and saves it there. A PATH that names a folder means the file in it named as BUFFER's file, or as the last part of BUFFER's name when it visits none."
  (check-path 'files:write-file path)
  (check-buffer 'files:write-file buffer)
  (check-task 'files:write-file)
  (let* ([path (true-path (%file-in-folder path buffer))] [other (buffer-at path)])
    (when (file-directory? path)
      (error 'files:write-file "is a folder" (abbreviated-path path)))
    (when (and other (not (eq? other buffer)))
      (assertion-violation 'files:write-file "another buffer visits the file" (abbreviated-path path)))
    (let ([e (move-entry! buffer path)])
      (with-entry-lock 'files:write-file e
        (lambda ()
          (when (entry-live? e)
            (save! 'files:write-file e)))))))

(define (%every-buffer buffer) #t)

(commands:define-command (save-some-buffers [predicate %every-buffer])
  "Asks, for each modified file buffer PREDICATE accepts, whether to save it, and saves each answered y."
  (check-main-thread 'files:save-some-buffers)
  (unless (procedure? predicate)
    (assertion-violation 'files:save-some-buffers "not a procedure" predicate))
  (for-each
    (lambda (b)
      (when (and (entry-of b) (buffers:modified? b) (predicate b)
                 (ask:y-or-n? (format "Save file ~a? " (abbreviated-path (path b))))
                 (entry-of b))
        (save-buffer b)))
    (visited-buffers)))

(define (%disk-fingerprints buffers)
  (run-operation 'files:revert-changed-buffers %fingerprinter (map (lambda (b) (entry-path (entry-of b))) buffers)))

;; The hunks go in last first, so each one's positions are still those of
;; the text they were found in; with no pause between them they are one
;; group to undo. The text is the file's, not the user's edit, so a
;; read-only buffer takes it too.
(define (%apply-hunks! buffer new hunks)
  (buffers:with-read-only-inhibited buffer
    (for-each (lambda (hunk)
                (apply (lambda (start end new-start new-end)
                         (buffers:replace! buffer start end (document:slice new new-start new-end)))
                       hunk))
              (reverse hunks))))

;; Typing goes on while a job reads the file, so the new text goes in only
;; if the buffer still has the text it was read against.
(define (%reload-unmodified! buffer checked)
  (let ([e (entry-of buffer)])
    (with-entry-lock 'files:revert-changed-buffers e
      (lambda ()
        (cond
          [(not (entry-live? e)) 'unchanged]
          [(buffers:modified? buffer) (entry-left-alone-set! e checked) 'left]
          [else
           (let* ([version (buffers:version buffer)]
                  [read (guard (c [(i/o-error? c) #f])
                          (run-job 'files:revert-changed-buffers %reverter (cons (entry-path e) (buffers:document buffer))
                            (lambda (read) (void)) e))]
                  [fingerprint (and read (list (contents-length (car read)) (contents-hash (car read))))])
             (cond
               [(or (not read) (not (entry-live? e))) 'unchanged]
               [(equal? fingerprint (list (entry-length e) (entry-hash e))) 'unchanged]
               [(and (= version (buffers:version buffer)) (not (buffers:modified? buffer)))
                (record-read! e (car read))
                (%apply-hunks! buffer (contents-document (car read)) (cdr read))
                (buffers:set-modified! buffer #f)
                (buffers:set-read-only! buffer (contents-write-protected? (car read)))
                (buffers:with-buffer buffer (after-revert buffer))
                'reloaded]
               [else (entry-left-alone-set! e fingerprint) 'left]))])))))

(define (revert-changed-buffers predicate)
  (check-main-thread 'files:revert-changed-buffers)
  (unless (procedure? predicate)
    (assertion-violation 'files:revert-changed-buffers "not a procedure" predicate))
  (check-task 'files:revert-changed-buffers)
  (let ([candidates (filter predicate (visited-buffers))])
    (let loop ([buffers candidates]
               [fingerprints (if (null? candidates) '() (%disk-fingerprints candidates))]
               [reloaded '()]
               [left '()])
      (if (null? buffers)
          (values (reverse reloaded) (reverse left))
          (let* ([b (car buffers)] [fingerprint (car fingerprints)] [e (and (buffers:live? b) (entry-of b))])
            (define (next reloaded left) (loop (cdr buffers) (cdr fingerprints) reloaded left))
            (cond
              [(or (not e) (not fingerprint)) (next reloaded left)]
              [(equal? fingerprint (list (entry-length e) (entry-hash e)))
               (entry-left-alone-set! e #f)
               (next reloaded left)]
              ;; A change left alone stays left alone, even once the buffer is
              ;; undone back to unmodified, since its edits were kept on
              ;; purpose; the file's next change is a change again.
              [(or (buffers:modified? b) (equal? fingerprint (entry-left-alone e)))
               (entry-left-alone-set! e fingerprint)
               (next reloaded (cons b left))]
              [else
               (case (%reload-unmodified! b fingerprint)
                 [(reloaded) (next (cons b reloaded) left)]
                 [(left) (next reloaded (cons b left))]
                 [else (next reloaded left)])]))))))

(commands:define-command (revert-from-file [buffer (buffers:current)])
  "Reads BUFFER's file again and replaces the lines that differ, as one edit."
  (let ([e (file-entry 'files:revert-from-file buffer)])
    (check-task 'files:revert-from-file)
    (with-entry-lock 'files:revert-from-file e
      (lambda ()
        (let retry ([tries 0])
          (let* ([version (buffers:version buffer)]
                 [old (buffers:document buffer)]
                 [read (run-job 'files:revert-from-file %reverter (cons (entry-path e) old) (lambda (read) (void)) e)])
            (cond
              [(not (entry-live? e)) (void)]
              [(and (not (= version (buffers:version buffer))) (fx< tries 2)) (retry (fx+ tries 1))]
              [else
               (let ([new (contents-document (car read))])
                 (record-read! e (car read))
                 (if (= version (buffers:version buffer))
                     (%apply-hunks! buffer new (cdr read))
                     (buffers:with-read-only-inhibited buffer
                       (buffers:replace! buffer 1 (fx- (document:length (buffers:document buffer)) 1)
                         (document:slice new 1 (fx- (document:length new) 1)))))
                 (buffers:set-modified! buffer #f)
                 (buffers:set-read-only! buffer (contents-write-protected? (car read)))
                 (buffers:with-buffer buffer (after-revert buffer))
                 (when (eq? (commands:this-command) revert-from-file)
                   (ask:message "Reverted buffer")))])))))))

(commands:define-command (not-modified [buffer (buffers:current)])
  "Marks BUFFER unmodified, as a save does, without writing."
  (check-buffer 'files:not-modified buffer)
  (buffers:set-modified! buffer #f))

(define (%unsaved-kept? buffer)
  (exists (lambda (entry) (entry buffer)) (hooks:entries unsaved-kept)))

(commands:define-command (save-buffers-kill-tuna)
  "Exits Tuna, asking first when a modified file buffer's edits would be lost, else when files:confirm-exit? is true."
  (check-main-thread 'files:save-buffers-kill-tuna)
  (when (if (for-all (lambda (b) (or (not (buffers:modified? b)) (%unsaved-kept? b)))
                     (visited-buffers))
            (or (not (confirm-exit?)) (ask:y-or-n? "Really exit Tuna? "))
            (ask:yes-or-no? "Modified buffers exist; exit anyway? "))
    (exit)))

(define (fingerprint buffer)
  (let ([e (file-entry 'files:fingerprint buffer)])
    (values (entry-length e) (entry-hash e))))

(define (canceled-condition? v)
  (%canceled? v))

(saved:define-saved recent-files '() (lambda (v) (and (list? v) (for-all string? v))))

(options:define-option recent-limit 20 (lambda (v) (or (not v) (and (fixnum? v) (fx>= v 0))))
  "How many paths files:recent-files keeps, the most recent; #f keeps every one.")

(hooks:define-hook recent-excluded
  "Called with a path before files:recent-files records it; an entry that returns true keeps it out.")

(define (%record-recent! buffer)
  (let ([p (path buffer)])
    (when (and p (not (exists (lambda (entry) (entry p)) (hooks:entries recent-excluded))))
      (let ([kept (cons p (remove p (recent-files)))] [n (recent-limit)])
        (saved:set! recent-files (if (and n (> (length kept) n)) (list-head kept n) kept))))))

(define (forget-recent! path)
  (check-path 'files:forget-recent! path)
  (when (member path (recent-files))
    (saved:set! recent-files (remove path (recent-files)))))

;; The list is filtered as it is when the job ends, since visits may have
;; changed it meanwhile.
(define (%forget-unreadable! paths)
  (unless (null? paths)
    (let ([gone (run-operation 'files:cleanup-recent %unreadable-finder paths)])
      (unless (null? gone)
        (saved:set! recent-files (remp (lambda (p) (member p gone)) (recent-files)))))))

(commands:define-command (cleanup-recent)
  "Removes the paths of files:recent-files whose files cannot be read."
  (check-main-thread 'files:cleanup-recent)
  (check-task 'files:cleanup-recent)
  (%forget-unreadable! (recent-files)))

;; Only the killed buffer's file is looked at, as Emacs's
;; recentf-track-closed-file does, so a kill reads nothing else.
(define (%forget-killed! buffer)
  (let ([p (path buffer)])
    (forget-killed! buffer)
    (when (and p (member p (recent-files)))
      (spawn-task (lambda (restore) (%forget-unreadable! (list p)))))))

;; A name that starts with a space marks an internal buffer, such as a
;; prompt's, which its plugin kills inside a command.
(define (%confirm-kill buffer)
  (let ([name (buffers:name buffer)])
    (or (not (commands:this-command))
        (not (buffers:modified? buffer))
        (%unsaved-kept? buffer)
        (and (not (entry-of buffer)) (not (buffers:with-buffer buffer (offer-save?))))
        (and (fx> (string-length name) 0) (char=? (string-ref name 0) #\space))
        (ask:y-or-n? (format "Buffer ~a has unsaved text; kill anyway? " name)))))

(define (%operation-path who path)
  (check-path who path)
  (check-task who)
  (true-folders-path path))

(define (%replace? who options)
  (unless (enum-set? options)
    (assertion-violation who "not file options" options))
  (enum-set-member? 'no-fail options))

(define rename-file
  (case-lambda
    [(from to) (rename-file from to (file-options))]
    [(from to options)
     (let* ([from (%operation-path 'files:rename-file from)] [to (%operation-path 'files:rename-file to)]
            [replace? (%replace? 'files:rename-file options)])
       (check-not-visited-under 'files:rename-file from to)
       (run-operation 'files:rename-file %renamer (list from to replace?)
         (lambda (v)
           (when (eq? v 'moved)
             (move-entries-under! from to)
             (after-rename from to))))
       (void))]))

(define copy-file
  (case-lambda
    [(from to) (copy-file from to (file-options))]
    [(from to options)
     (let* ([from (%operation-path 'files:copy-file from)] [to (%operation-path 'files:copy-file to)]
            [replace? (%replace? 'files:copy-file options)])
       (run-operation 'files:copy-file %copier (list from to replace?))
       (void))]))

(define (delete-file path)
  (run-operation 'files:delete-file %deleter (%operation-path 'files:delete-file path))
  (void))

(define (move-to-trash path)
  (run-operation 'files:move-to-trash %trasher (%operation-path 'files:move-to-trash path))
  (void))

(define (make-folder path)
  (run-operation 'files:make-folder %folder-creator (%operation-path 'files:make-folder path))
  (void))

(hooks:add! buffers:killed %forget-killed!)
(hooks:add! after-visit %record-recent!)
(hooks:add! after-save %record-recent!)
(hooks:add! buffers:kill-queries %confirm-kill)
(options:set! buffers:revert-function revert-from-file)
(hooks:add! directory-finders file-directory -10)
(tables:set! commands:command-modes revert-from-file '())
(keys:bind! keys:global "C-x C-w" write-file)
(keys:bind! keys:global "C-x C-s" save-buffer)
(keys:bind! keys:global "C-x s" save-some-buffers)
(keys:bind! keys:global "M-~" not-modified)
(keys:bind! keys:global "C-x C-c" save-buffers-kill-tuna)
(keys:bind! keys:global "C-x x g" buffers:revert-buffer)
(on-unload save-visits!)
(on-unload stop-waiting!)
(take-back!)
(spawn-task (lambda (restore) (open-pending! visit)))
(spawn-task (lambda (restore) (%forget-unreadable! (recent-files))))
