#!tuna
(import (processes) (diff) (git state) (hooks) (options))

(options:define-option program "git" string? "The git program run.")

(options:define-option global-arguments
  '("--no-pager" "--literal-pathspecs" "-c" "core.preloadindex=true" "-c" "log.showSignature=false"
    "-c" "color.ui=false" "-c" "color.diff=false" "-c" "diff.noPrefix=false" "-c" "diff.mnemonicPrefix=false"
    "-c" "diff.srcPrefix=a/" "-c" "diff.dstPrefix=b/" "-c" "diff.suppressBlankEmpty=false" "-c" "core.quotePath=false")
  (lambda (v) (and (list? v) (for-all string? v)))
  "Arguments put before every subcommand, so a user's git configuration cannot change the output git parses.")

(options:define-option environment
  '(("GIT_TERMINAL_PROMPT" . "0") ("GIT_SSH_COMMAND" . "ssh -o BatchMode=yes") ("LC_ALL" . "C.UTF-8"))
  processes:environment?
  "Variables added to git's environment.")

(options:define-option diff-arguments '() (lambda (v) (and (list? v) (for-all string? v)))
  "Arguments every git:diff adds, such as \"--histogram\" or \"-w\".")

(options:define-option command-log-size 32 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many commands each repository's log keeps.")

(hooks:define-hook command-updated
  "Called with a repository and a command when the command is queued, starts, gets output and ends.")

(hooks:define-hook command-ended
  "Called with a repository and a command after the command ends, whatever its status.")

(define-enumeration untracked-listing (normal all no) %untracked-listings)

(define (command? v) (%command? v))

(define-condition-type &failed &error %make-failed failed-condition? (command failure-command))

(define-record-type (%status %make-status status?)
  (sealed #t)
  (fields branch head upstream ahead behind entries untracked))

(define-record-type (%entry %make-entry entry?)
  (sealed #t)
  (fields path-bytes original-path-bytes index worktree))

(define-record-type (%commit %make-commit commit?)
  (sealed #t)
  (fields name short-name refs subject))

(module %internals
  (check-repository check-arguments check-paths repository-vector call-git logged-command start-command
   failure-condition summary-of output-of bytes-join split-bytes lines text with-slash
   status-of untracked-of commits-of first-commit? paths-input stop-command! state-of log-of)

  (define (repository-vector root git-folder) (vector 'git-repository root git-folder))

  (define (check-repository who v)
    (unless (and (vector? v) (fx= (vector-length v) 3) (eq? (vector-ref v 0) 'git-repository))
      (assertion-violation who "not a repository" v)))

  (define (check-arguments who v)
    (unless (and (list? v) (for-all string? v))
      (assertion-violation who "not a list of strings" v)))

  (define (check-paths who v)
    (unless (and (list? v) (pair? v) (for-all (lambda (p) (or (string? p) (bytevector? p))) v))
      (assertion-violation who "not a list of paths, strings or bytevectors" v)))

  (define (text bytes) (utf8->string bytes))

  (define (with-slash path)
    (if (and (fx> (string-length path) 0) (char=? (string-ref path (fx- (string-length path) 1)) #\/))
        path
        (string-append path "/")))

  (define (bytes-join parts)
    (let-values ([(out done) (open-bytevector-output-port)])
      (for-each (lambda (p) (put-bytevector out p)) parts)
      (done)))

  (define (split-bytes bytes separator)
    (let ([n (bytevector-length bytes)])
      (let loop ([start 0] [i 0] [acc '()])
        (cond
          [(fx= i n)
           (reverse (if (fx= start n) acc (cons (let ([p (make-bytevector (fx- n start))])
                                                  (bytevector-copy! bytes start p 0 (fx- n start))
                                                  p)
                                                acc)))]
          [(fx= (bytevector-u8-ref bytes i) separator)
           (let ([p (make-bytevector (fx- i start))])
             (bytevector-copy! bytes start p 0 (fx- i start))
             (loop (fx+ i 1) (fx+ i 1) (cons p acc)))]
          [else (loop start (fx+ i 1) acc)]))))

  (define (lines bytes) (map text (split-bytes bytes 10)))

  (define (paths-input paths)
    (bytes-join (fold-right (lambda (p acc) (cons* (if (string? p) (string->utf8 p) p) #vu8(0) acc)) '() paths)))

  (define (output-of command) (bytes-join (reverse (%command-parts command))))

  (define (starts-with? s prefix)
    (and (fx>= (string-length s) (string-length prefix))
         (string=? (substring s 0 (string-length prefix)) prefix)))

  (define (trim s)
    (let* ([n (string-length s)]
           [start (let loop ([i 0]) (if (and (fx< i n) (char-whitespace? (string-ref s i))) (loop (fx+ i 1)) i))]
           [end (let loop ([i n]) (if (and (fx> i start) (char-whitespace? (string-ref s (fx- i 1)))) (loop (fx- i 1)) i))])
      (substring s start end)))

  (define (summary-of output)
    (let* ([ls (filter (lambda (l) (not (string=? (trim l) ""))) (lines output))]
           [marked (filter (lambda (l) (or (starts-with? l "fatal:") (starts-with? l "error:"))) ls)])
      (cond
        [(pair? marked)
         (let ([l (car (reverse marked))])
           (trim (substring l 6 (string-length l))))]
        [(pair? ls) (trim (car (reverse ls)))]
        [else "git failed"])))

  (define (failure-condition command)
    (condition (%make-failed command) (make-who-condition 'git)
               (make-message-condition (summary-of (output-of command)))))

  (define (environment-with extra)
    (let ([base (environment)])
      (append (filter (lambda (pair) (not (assoc (car pair) extra))) base) extra)))

  ;; Queries take no optional lock, such as the one git status takes to
  ;; refresh the index, so a command running beside one never finds the
  ;; index locked.
  (define (call-git root arguments input)
    (let-values ([(status out err)
                  (processes:run (program) (append '("--no-optional-locks") (global-arguments) arguments) input
                    (processes:options [directory root] [environment (environment)] [separate-stderr #t]))])
      (values status out err)))

  (define (state-of repository)
    (let ([root (vector-ref repository 1)])
      (or (hashtable-ref states root #f)
          (let ([s (make-state '() '() #f)])
            (hashtable-set! states root s)
            s))))

  (define (log-of repository) (state-log (state-of repository)))

  (define (log! state command)
    (let* ([log (append (state-log state) (list command))]
           [extra (fx- (length log) (command-log-size))])
      (state-log-set! state (if (fx> extra 0) (list-tail log extra) log))))

  (define (updated command) (command-updated (%command-repository command) command))

  (define (start-next! state)
    (when (and (not (state-running state)) (pair? (state-queue state)))
      (let ([entry (car (state-queue state))])
        (state-queue-set! state (cdr (state-queue state)))
        (state-running-set! state (car entry))
        ((cdr entry)))))

  (define (note-output! command bytes stdout?)
    (unless (eof-object? bytes)
      (%command-parts-set! command (cons bytes (%command-parts command)))
      (when stdout?
        (%command-out-parts-set! command (cons bytes (%command-out-parts command))))
      (updated command)))

  ;; on-end runs before git:command-ended, so a starter can mark the
  ;; command canceled before the hook's entries read it.
  (define (end! state command status on-end)
    (when (condition? status)
      (note-output! command (string->utf8 (string-append (if (message-condition? status) (condition-message status) "git did not start") "\n")) #f))
    (%command-exit-set! command (if (fixnum? status) status 127))
    (%command-process-set! command #f)
    (when (eq? (state-running state) command)
      (state-running-set! state #f))
    (updated command)
    (on-end command)
    (command-ended (%command-repository command) command)
    (start-next! state))

  (define (enqueue! command starter)
    (let ([state (state-of (%command-repository command))])
      (log! state command)
      (state-queue-set! state (append (state-queue state) (list (cons command starter))))
      (updated command)
      (start-next! state)))

  ;; A command keeps standard output apart from standard error, which
  ;; joins the log only, so git:run returns what git printed alone.
  (define (start-command repository arguments input extra-environment wrapper on-end)
    (let ([command (%make-command repository arguments #f '() '() #f #f #f)]
          [root (vector-ref repository 1)])
      (enqueue! command
        (lambda ()
          (let ([state (state-of repository)])
            (if (%command-stopped? command)
                (end! state command -1 on-end)
                (let* ([log-output (lambda (bytes end) (note-output! command bytes #t))]
                       [process
                        (guard (c [(not (cancelled? c)) (end! state command c on-end) #f])
                          (processes:start (program) (append (global-arguments) arguments)
                            (if wrapper (wrapper log-output) log-output)
                            (lambda (status) (end! state command status on-end))
                            (processes:options [directory root] [environment (environment-with extra-environment)])
                            (lambda (bytes end) (note-output! command bytes #f))))])
                  (when process
                    (%command-process-set! command process)
                    (updated command)
                    (if input (processes:send! process input))
                    (processes:close-input! process)))))))
      command))

  (define (logged-command repository arguments input)
    (suspend
      (lambda (resume)
        (start-command repository arguments input '() #f
          (lambda (command)
            (resume
              (lambda ()
                (if (eqv? (%command-exit command) 0)
                    (bytes-join (reverse (%command-out-parts command)))
                    (raise (failure-condition command))))))))))

  (define (stop-command! command)
    (cond
      [(%command-exit command) (error 'git:stop! "Process isn't running")]
      [(%command-process command) (processes:stop! (%command-process command))]
      [else (%command-stopped?-set! command #t)]))

  (define (letter->change c)
    (case c
      [(#\.) 'unmodified]
      [(#\M) 'modified]
      [(#\T) 'type-changed]
      [(#\A) 'added]
      [(#\D) 'deleted]
      [(#\R) 'renamed]
      [(#\C) 'copied]
      [(#\U) 'unmerged]
      [else 'unmodified]))

  (define (after-fields bytes count)
    (let ([n (bytevector-length bytes)])
      (let loop ([i 0] [spaces 0])
        (cond
          [(fx= spaces count) (let ([p (make-bytevector (fx- n i))]) (bytevector-copy! bytes i p 0 (fx- n i)) p)]
          [(fx= i n) #vu8()]
          [(fx= (bytevector-u8-ref bytes i) 32) (loop (fx+ i 1) (fx+ spaces 1))]
          [else (loop (fx+ i 1) spaces)]))))

  (define (status-of output untracked)
    (let loop ([tokens (split-bytes output 0)] [branch #f] [head #f] [upstream #f] [ahead 0] [behind 0] [entries '()])
      (define (header-value line prefix) (substring line (string-length prefix) (string-length line)))
      (if (null? tokens)
          (%make-status branch head upstream ahead behind (reverse entries) untracked)
          (let* ([token (car tokens)]
                 [kind (if (fx> (bytevector-length token) 1) (integer->char (bytevector-u8-ref token 0)) #\space)])
            (case kind
              [(#\#)
               (let ([line (text token)])
                 (cond
                   [(starts-with? line "# branch.oid ")
                    (let ([v (header-value line "# branch.oid ")])
                      (loop (cdr tokens) branch (and (not (string=? v "(initial)")) v) upstream ahead behind entries))]
                   [(starts-with? line "# branch.head ")
                    (let ([v (header-value line "# branch.head ")])
                      (loop (cdr tokens) (and (not (string=? v "(detached)")) v) head upstream ahead behind entries))]
                   [(starts-with? line "# branch.upstream ")
                    (loop (cdr tokens) branch head (header-value line "# branch.upstream ") ahead behind entries)]
                   [(starts-with? line "# branch.ab ")
                    (let* ([v (header-value line "# branch.ab ")]
                           [space (let find ([i 0]) (if (char=? (string-ref v i) #\space) i (find (fx+ i 1))))])
                      (loop (cdr tokens) branch head upstream
                            (string->number (substring v 1 space))
                            (string->number (substring v (fx+ space 2) (string-length v)))
                            entries))]
                   [else (loop (cdr tokens) branch head upstream ahead behind entries)]))]
              [(#\1 #\2 #\u)
               (let* ([xy (cons (integer->char (bytevector-u8-ref token 2)) (integer->char (bytevector-u8-ref token 3)))]
                      [path (after-fields token (case kind [(#\1) 8] [(#\2) 9] [else 10]))]
                      [original (and (char=? kind #\2) (pair? (cdr tokens)) (cadr tokens))]
                      [entry (if (char=? kind #\u)
                                 (%make-entry path #f 'unmerged 'unmerged)
                                 (%make-entry path original (letter->change (car xy)) (letter->change (cdr xy))))])
                 (loop (if original (cddr tokens) (cdr tokens)) branch head upstream ahead behind (cons entry entries)))]
              [else (loop (cdr tokens) branch head upstream ahead behind entries)])))))

  (define (bytes<? a b)
    (let ([na (bytevector-length a)] [nb (bytevector-length b)])
      (let loop ([i 0])
        (cond
          [(fx= i nb) #f]
          [(fx= i na) #t]
          [(fx= (bytevector-u8-ref a i) (bytevector-u8-ref b i)) (loop (fx+ i 1))]
          [else (fx< (bytevector-u8-ref a i) (bytevector-u8-ref b i))]))))

  (define (untracked-of output)
    (list-sort bytes<? (split-bytes output 0)))

  (define (commits-of output)
    (map (lambda (line)
           (let ([fields (split-bytes (string->utf8 line) 0)])
             (%make-commit (text (list-ref fields 0)) (text (list-ref fields 1))
                           (refs-of (if (fx> (length fields) 2) (text (list-ref fields 2)) ""))
                           (if (fx> (length fields) 3) (text (list-ref fields 3)) ""))))
         (filter (lambda (l) (not (string=? l ""))) (lines output))))

  (define (refs-of decoration)
    (let loop ([i 0] [start 0] [acc '()])
      (define (piece) (substring decoration start i))
      (define (ref s) (if (starts-with? s "HEAD -> ") (substring s 8 (string-length s)) s))
      (cond
        [(fx= i (string-length decoration))
         (reverse (if (fx= start i) acc (cons (ref (piece)) acc)))]
        [(and (char=? (string-ref decoration i) #\,) (fx< (fx+ i 1) (string-length decoration))
              (char=? (string-ref decoration (fx+ i 1)) #\space))
         (loop (fx+ i 2) (fx+ i 2) (cons (ref (piece)) acc))]
        [else (loop (fx+ i 1) start acc)])))

  (define (first-commit? repository)
    (let-values ([(status out err) (call-git (vector-ref repository 1) '("rev-parse" "--verify" "-q" "HEAD") #f)])
      (not (eqv? status 0)))))

(import %internals)

(define (find-repository folder)
  (unless (and (string? folder) (fx> (string-length folder) 0) (char=? (string-ref folder 0) #\/))
    (assertion-violation 'git:find-repository "not an absolute path" folder))
  (and (file-directory? folder)
       (let-values ([(status out err) (call-git folder '("rev-parse" "--show-toplevel" "--absolute-git-dir") #f)])
         (and (eqv? status 0)
              (let ([ls (lines out)])
                (and (fx= (length ls) 2)
                     (repository-vector (with-slash (car ls)) (with-slash (cadr ls)))))))))

(define (repository? v)
  (and (vector? v) (fx= (vector-length v) 3) (eq? (vector-ref v 0) 'git-repository)))

(define (repository-root repository)
  (check-repository 'git:repository-root repository)
  (vector-ref repository 1))

(define (repository-git-folder repository)
  (check-repository 'git:repository-git-folder repository)
  (vector-ref repository 2))

(define (repository-name repository)
  (check-repository 'git:repository-name repository)
  (let* ([root (vector-ref repository 1)] [end (fx- (string-length root) 1)])
    (let loop ([i (fx- end 1)])
      (cond
        [(fx< i 0) (substring root 0 end)]
        [(char=? (string-ref root i) #\/) (substring root (fx+ i 1) end)]
        [else (loop (fx- i 1))]))))

(define (%check-input who input)
  (unless (or (not input) (bytevector? input))
    (assertion-violation who "not a bytevector or #f" input)))

(define query
  (case-lambda
    [(repository arguments) (query repository arguments #f)]
    [(repository arguments input)
     (check-repository 'git:query repository)
     (check-arguments 'git:query arguments)
     (%check-input 'git:query input)
     (let-values ([(status out err) (call-git (vector-ref repository 1) arguments input)])
       (if (eqv? status 0)
           out
           (let ([command (%make-command repository arguments status (list err out) (list out) #f #f #f)])
             (raise (failure-condition command)))))]))

(define run
  (case-lambda
    [(repository arguments) (run repository arguments #f)]
    [(repository arguments input)
     (check-repository 'git:run repository)
     (check-arguments 'git:run arguments)
     (%check-input 'git:run input)
     (logged-command repository arguments input)]))

(define start
  (case-lambda
    [(repository arguments on-end) (start repository arguments on-end #f #f)]
    [(repository arguments on-end options) (start repository arguments on-end options #f)]
    [(repository arguments on-end options wrapper)
     (check-repository 'git:start repository)
     (check-arguments 'git:start arguments)
     (unless (procedure? on-end)
       (assertion-violation 'git:start "not a procedure" on-end))
     (unless (or (not wrapper) (procedure? wrapper))
       (assertion-violation 'git:start "not a procedure or #f" wrapper))
     (when options
       (unless (processes:options? options)
         (assertion-violation 'git:start "not processes:options" options))
       (when (or (processes:options-directory options) (processes:options-terminal options)
                 (processes:options-separate-stderr options) (processes:options-full-log options))
         (assertion-violation 'git:start "git:start takes an environment only" options)))
     (start-command repository arguments #f
                    (or (and options (processes:options-environment options)) '())
                    wrapper on-end)]))

(define (init folder)
  (unless (and (string? folder) (fx> (string-length folder) 0) (char=? (string-ref folder 0) #\/))
    (assertion-violation 'git:init "not an absolute path" folder))
  (let-values ([(status out err) (call-git "/" (list "init" "--" folder) #f)])
    (let ([repository (find-repository folder)])
      (unless (and (eqv? status 0) repository)
        (raise (failure-condition (%make-command (repository-vector (with-slash folder) "") '("init") status (list err out) (list out) #f #f #f))))
      (let ([command (%make-command repository '("init") status (list err out) (list out) #f #f #f)])
        (let ([state (state-of repository)])
          (state-log-set! state (append (state-log state) (list command))))
        (command-updated repository command)
        (command-ended repository command)
        repository))))

(define (failure-summary condition)
  (unless (failed-condition? condition)
    (assertion-violation 'git:failure-summary "not a git:&failed condition" condition))
  (condition-message condition))

(define (commands repository)
  (check-repository 'git:commands repository)
  (log-of repository))

(define (command-arguments command)
  (unless (command? command)
    (assertion-violation 'git:command-arguments "not a command" command))
  (%command-arguments command))

(define (command-exit command)
  (unless (command? command)
    (assertion-violation 'git:command-exit "not a command" command))
  (%command-exit command))

(define (command-canceled? command)
  (unless (command? command)
    (assertion-violation 'git:command-canceled? "not a command" command))
  (%command-canceled? command))

(define (command-output command)
  (unless (command? command)
    (assertion-violation 'git:command-output "not a command" command))
  (utf8->string (output-of command)))

(define (set-command-canceled! command)
  (unless (command? command)
    (assertion-violation 'git:set-command-canceled! "not a command" command))
  (%command-canceled?-set! command #t))

(define (running repository)
  (check-repository 'git:running repository)
  (state-running (state-of repository)))

(define (queued? repository)
  (check-repository 'git:queued? repository)
  (let ([state (state-of repository)])
    (or (and (state-running state) #t) (pair? (state-queue state)))))

(define (stop! command)
  (unless (command? command)
    (assertion-violation 'git:stop! "not a command" command))
  (stop-command! command))

(define (status repository)
  (check-repository 'git:status repository)
  (let ([output (query repository '("status" "--porcelain=v2" "--branch" "-z" "--untracked-files=no"))])
    (status-of output (untracked repository #f))))

(define (%checked who check message accessor)
  (lambda (v)
    (unless (check v)
      (assertion-violation who message v))
    (accessor v)))

(define (status-branch status)
  ((%checked 'git:status-branch status? "not a status" %status-branch) status))

(define (status-head status)
  ((%checked 'git:status-head status? "not a status" %status-head) status))

(define (status-upstream status)
  ((%checked 'git:status-upstream status? "not a status" %status-upstream) status))

(define (status-ahead status)
  ((%checked 'git:status-ahead status? "not a status" %status-ahead) status))

(define (status-behind status)
  ((%checked 'git:status-behind status? "not a status" %status-behind) status))

(define (status-entries status)
  ((%checked 'git:status-entries status? "not a status" %status-entries) status))

(define (status-untracked status)
  ((%checked 'git:status-untracked status? "not a status" %status-untracked) status))

(define (entry-path entry)
  (utf8->string ((%checked 'git:entry-path entry? "not a status entry" %entry-path-bytes) entry)))

(define (entry-path-bytes entry)
  ((%checked 'git:entry-path-bytes entry? "not a status entry" %entry-path-bytes) entry))

(define (entry-original-path entry)
  (let ([b ((%checked 'git:entry-original-path entry? "not a status entry" %entry-original-path-bytes) entry)])
    (and b (utf8->string b))))

(define (entry-original-path-bytes entry)
  ((%checked 'git:entry-original-path-bytes entry? "not a status entry" %entry-original-path-bytes) entry))

(define (entry-index entry)
  ((%checked 'git:entry-index entry? "not a status entry" %entry-index) entry))

(define (entry-worktree entry)
  ((%checked 'git:entry-worktree entry? "not a status entry" %entry-worktree) entry))

(define (untracked repository listing)
  (check-repository 'git:untracked repository)
  (unless (or (not listing) (memq listing (enum-set->list (enum-set-universe (%untracked-listings)))))
    (assertion-violation 'git:untracked "not a git:untracked-listing or #f" listing))
  (let ([how (or listing
                 (let ([setting (config repository "status.showUntrackedFiles")])
                   (cond
                     [(member setting '("no" "false" "off" "0")) 'no]
                     [(equal? setting "all") 'all]
                     [else 'normal])))])
    (if (eq? how 'no)
        '()
        (untracked-of
          (query repository
                 (append '("ls-files" "--others" "--exclude-standard" "-z")
                         (if (eq? how 'normal) '("--directory" "--no-empty-directory") '())))))))

(define (diff repository arguments)
  (check-repository 'git:diff repository)
  (check-arguments 'git:diff arguments)
  (diff:parse (query repository (append '("diff" "-p" "--no-ext-diff" "--no-textconv") (diff-arguments) arguments))))

(define (commits repository range count)
  (check-repository 'git:commits repository)
  (unless (string? range)
    (assertion-violation 'git:commits "not a string" range))
  (unless (or (not count) (and (fixnum? count) (fx> count 0)))
    (assertion-violation 'git:commits "not a positive count or #f" count))
  (commits-of
    (query repository
           (append '("log" "--format=%H%x00%h%x00%D%x00%s")
                   (if count (list "-n" (number->string count)) '())
                   (list range "--")))))

(define (commit-name commit)
  ((%checked 'git:commit-name commit? "not a commit" %commit-name) commit))

(define (commit-short-name commit)
  ((%checked 'git:commit-short-name commit? "not a commit" %commit-short-name) commit))

(define (commit-subject commit)
  ((%checked 'git:commit-subject commit? "not a commit" %commit-subject) commit))

(define (commit-refs commit)
  ((%checked 'git:commit-refs commit? "not a commit" %commit-refs) commit))

(define (stashes repository)
  (check-repository 'git:stashes repository)
  (map (lambda (line)
         (let ([fields (split-bytes (string->utf8 line) 0)])
           (cons (text (car fields)) (if (pair? (cdr fields)) (text (cadr fields)) ""))))
       (filter (lambda (l) (not (string=? l ""))) (lines (query repository '("stash" "list" "--format=%gd%x00%gs"))))))

(define (stage repository paths)
  (check-repository 'git:stage repository)
  (check-paths 'git:stage paths)
  (run repository '("add" "--pathspec-from-file=-" "--pathspec-file-nul") (paths-input paths))
  (void))

(define (stage-intent-to-add repository paths)
  (check-repository 'git:stage-intent-to-add repository)
  (check-paths 'git:stage-intent-to-add paths)
  (run repository '("add" "--intent-to-add" "--pathspec-from-file=-" "--pathspec-file-nul") (paths-input paths))
  (void))

(define (stage-tracked repository)
  (check-repository 'git:stage-tracked repository)
  (run repository '("add" "-u" "."))
  (void))

(define (stage-all repository)
  (check-repository 'git:stage-all repository)
  (run repository '("add" "--all" "."))
  (void))

(define (unstage repository paths)
  (check-repository 'git:unstage repository)
  (when paths (check-paths 'git:unstage paths))
  (cond
    [(first-commit? repository)
     (if paths
         (run repository '("rm" "--cached" "-q" "-r" "--pathspec-from-file=-" "--pathspec-file-nul") (paths-input paths))
         (run repository '("rm" "--cached" "-q" "-r" "--" ".")))]
    [paths (run repository '("reset" "-q" "HEAD" "--pathspec-from-file=-" "--pathspec-file-nul") (paths-input paths))]
    [else (run repository '("reset" "-q" "HEAD" "--"))])
  (void))

(define (restore-from-index repository paths)
  (check-repository 'git:restore-from-index repository)
  (check-paths 'git:restore-from-index paths)
  (run repository '("checkout" "--pathspec-from-file=-" "--pathspec-file-nul") (paths-input paths))
  (void))

(define (restore-from-head repository paths)
  (check-repository 'git:restore-from-head repository)
  (check-paths 'git:restore-from-head paths)
  (run repository '("checkout" "HEAD" "--pathspec-from-file=-" "--pathspec-file-nul") (paths-input paths))
  (void))

(define (apply repository patch arguments)
  (check-repository 'git:apply repository)
  (unless (bytevector? patch)
    (assertion-violation 'git:apply "not a bytevector" patch))
  (check-arguments 'git:apply arguments)
  (run repository (append '("apply" "-p1" "--whitespace=nowarn") arguments '("-")) patch)
  (void))

(define (config repository key)
  (check-repository 'git:config repository)
  (unless (string? key)
    (assertion-violation 'git:config "not a string" key))
  (let-values ([(status out err) (call-git (vector-ref repository 1) (list "config" "--get" key) #f)])
    (and (eqv? status 0)
         (let ([ls (lines out)]) (and (pair? ls) (car ls))))))

(define (set-config! repository key value)
  (check-repository 'git:set-config! repository)
  (unless (string? key)
    (assertion-violation 'git:set-config! "not a string" key))
  (unless (or (not value) (string? value))
    (assertion-violation 'git:set-config! "not a string or #f" value))
  (cond
    [value (run repository (list "config" key value))]
    [(config repository key) (run repository (list "config" "--unset" key))])
  (void))

(define (remotes repository)
  (check-repository 'git:remotes repository)
  (filter (lambda (l) (not (string=? l ""))) (lines (query repository '("remote")))))

(define (remote-branches repository)
  (check-repository 'git:remote-branches repository)
  (fold-right
    (lambda (line acc)
      (let ([fields (split-bytes (string->utf8 line) 0)])
        (if (or (null? fields) (pair? (cdr fields))) acc (cons (text (car fields)) acc))))
    '()
    (filter (lambda (l) (not (string=? l "")))
            (lines (query repository '("for-each-ref" "--format=%(refname:short)%00%(symref)" "refs/remotes"))))))

(define (upstream repository branch)
  (check-repository 'git:upstream repository)
  (unless (string? branch)
    (assertion-violation 'git:upstream "not a string" branch))
  (let-values ([(status out err)
                (call-git (vector-ref repository 1)
                          (list "rev-parse" "--abbrev-ref" "--symbolic-full-name" (string-append branch "@{upstream}")) #f)])
    (and (eqv? status 0)
         (let ([ls (lines out)]) (and (pair? ls) (car ls))))))

(define (push-remote repository branch)
  (check-repository 'git:push-remote repository)
  (unless (string? branch)
    (assertion-violation 'git:push-remote "not a string" branch))
  (or (config repository (string-append "branch." branch ".pushRemote"))
      (config repository "remote.pushDefault")))

(define (user repository)
  (check-repository 'git:user repository)
  (values (config repository "user.name") (config repository "user.email")))
