(library (tuna installs)
  (export
    install-id?
    delete-tree
    write-file-atomically!
    run-git
    git
    checked-out-commit
    commits-equal?
    check-out!
    clone!
    fetch!
    commit-present?
    ancestor?
    build!
    run-build!
    call-paused
    check-not-fetching
    fetching?
    source-extensions
    library-files
    tuna-file?
    reserved-library-name?)
  (import (chezscheme) (tuna process) (tuna files)
          (only (tuna core changes) find-owner)
          (only (tuna core modules) running-module-body)
          (only (tuna core main-thread) post-task! suspend current-task))

  ;; An id names a folder beside the .<id>.new and .<id>.old folders an
  ;; install moves aside.
  (define (install-id? x)
    (and (symbol? x)
         (let ([s (symbol->string x)])
           (and (fx> (string-length s) 0)
                (not (char=? (string-ref s 0) #\.))
                (not (memv #\/ (string->list s)))))))

  (define (delete-tree path)
    (cond
      [(file-directory? path #f)
       (for-each (lambda (entry) (delete-tree (string-append path "/" entry))) (directory-list path))
       (delete-directory path)]
      [(file-exists? path #f) (delete-file path)]))

  (define (write-file-atomically! path text)
    (let ([temporary (string-append path ".new")])
      (call-with-port
        (open-file-output-port temporary (file-options no-fail) (buffer-mode block)
          (make-transcoder (utf-8-codec)))
        (lambda (p) (put-string p text)))
      (rename-file temporary path)))

  (define (last-line text)
    (let loop ([lines '()] [p (open-string-input-port text)])
      (let ([line (get-line p)])
        (if (eof-object? line)
            (or (find (lambda (line) (not (string=? line ""))) lines) "")
            (loop (cons line lines) p)))))

  ;; In a session of its own git has no terminal, so ssh fails where it
  ;; would ask for a passphrase or a host key.
  (define (run-git arguments)
    (run-program "setsid" (cons* "-w" "env" "GIT_TERMINAL_PROMPT=0" "git" arguments)))

  (define (git who url . arguments)
    (let-values ([(status output) (run-git arguments)])
      (unless (eqv? status 0)
        (errorf who "git failed for ~a: ~a" url (last-line output)))))

  ;; Tuna checks out detached, so HEAD holds the commit.
  (define (checked-out-commit folder)
    (let ([head (string-append folder "/.git/HEAD")])
      (and (file-exists? head)
           (let ([line (call-with-input-file head get-line)])
             (and (string? line)
                  (fx>= (string-length line) 40)
                  (for-all (lambda (c) (memv c (string->list "0123456789abcdef"))) (string->list line))
                  line)))))

  ;; A commit may be written abbreviated.
  (define (commits-equal? a b)
    (if (fx<= (string-length a) (string-length b))
        (string-prefix? a b)
        (string-prefix? b a)))

  (define (commit-present? folder commit)
    (let-values ([(status output)
                  (run-git (list "-C" folder "rev-parse" "--quiet" "--verify" (string-append commit "^{commit}")))])
      (eqv? status 0)))

  (define (ancestor? folder a b)
    (let-values ([(status output) (run-git (list "-C" folder "merge-base" "--is-ancestor" a b))])
      (eqv? status 0)))

  (define (check-out! who url folder commit branch)
    (let ([revision (cond [commit commit] [branch (string-append "origin/" branch)] [else "origin/HEAD"])])
      (unless (commit-present? folder revision)
        (cond
          [commit (errorf who "commit ~a not found in ~a" commit url)]
          [branch (errorf who "branch ~a not found in ~a" branch url)]
          [else (errorf who "~a has no default branch" url)]))
      (git who url "-C" folder "checkout" "--quiet" "--detach" revision)
      (checked-out-commit folder)))

  ;; Runs on any thread: it touches only the folder it fills.
  (define (clone! who url commit branch target)
    (delete-tree target)
    (guard (c [#t (delete-tree target) (raise c)])
      (git who url "clone" "--quiet" "--no-checkout" url target)
      (check-out! who url target commit branch)))

  (define (fetch! who url folder commit branch)
    (git who url "-C" folder "remote" "set-url" "origin" url)
    (git who url "-C" folder "fetch" "--quiet" "origin")
    (check-out! who url folder commit branch))

  ;; Third-party code, Scheme included, comes in as submodules, so they are
  ;; fetched for every checkout.
  (define (build! who name url folder root command program log)
    (git who url "-C" folder "submodule" "--quiet" "update" "--init" "--recursive")
    (run-build! who name folder root command program log))

  ;; The build runs in a process of its own, so one that crashes, loops,
  ;; exits or changes its directory leaves Tuna running; it has no
  ;; terminal, as git has none. It is no part of a make that may have
  ;; started Tuna, so it must not join that make's job server; and a
  ;; makefile's $(SCHEME) is Tuna's own Chez. A submodule's .git is a file,
  ;; so its commit is not known here.
  (define (run-build! who name folder root command program log)
    (let ([command (or command
                       (if (file-exists? (string-append root "/build.ss"))
                           (list program "--script" "build.ss")
                           '()))])
      (unless (null? command)
        (let-values ([(status output)
                      (run-program "setsid"
                        (cons* "-w" "env" "-C" root "-u" "MAKEFLAGS" "-u" "MAKELEVEL" "-u" "MFLAGS"
                               "GIT_TERMINAL_PROMPT=0" (string-append "SCHEME=" program) command))])
          (make-folders! (path-parent log))
          (call-with-output-file log
            (lambda (p) (fprintf p "build~@[ of ~a~], status ~a\n~a" (checked-out-commit folder) status output))
            'append)
          (unless (eqv? status 0)
            (errorf who "the build of ~a failed with status ~a: ~a (output in ~a)"
              name status (last-line output) log))))))

  ;; While git runs for a folder, its task pauses and the main thread goes
  ;; on, so another install could start and share the folder.
  (define fetching '())

  (define (fetching? folder) (and (member folder fetching) #t))

  (define (check-not-fetching who folder what)
    (when (fetching? folder)
      (assertion-violation who (string-append "git is running for the " what) (string->symbol (path-last folder)))))

  ;; A quit ends the task while git may still fill the folder, so the
  ;; folder stays taken until both git and the task are done. git's end is
  ;; posted before the resume, so it is counted first when no quit came,
  ;; and on behalf of (tuna), so that it runs whichever module is unloaded
  ;; meanwhile. Code that cannot pause, outside a task or in a module's
  ;; body, waits for git.
  (define (call-paused who folder what thunk)
    (check-not-fetching who folder what)
    (if (or (not (current-task)) (running-module-body))
        (thunk)
        (begin
          (set! fetching (cons folder fetching))
          (let ([forked? #f] [running 2])
            (define (done!)
              (set! running (fx- running 1))
              (when (fx= running 0)
                (set! fetching (remove folder fetching))))
            (let ([result (guard (c [#t (if forked? (done!) (set! fetching (remove folder fetching))) (raise c)])
                            (suspend
                              (lambda (resume)
                                (set! forked? #t)
                                (fork-thread
                                  (lambda ()
                                    (let ([result (guard (c [#t (lambda () (raise c))])
                                                    (let ([v (thunk)]) (lambda () v)))])
                                      (post-task! done! (find-owner '(tuna)))
                                      (resume result)))))))])
              (done!)
              result)))))

  (define (source-extensions) (map car (library-extensions)))

  (define (strip-extension entry extensions)
    (exists (lambda (extension)
              (let ([n (string-length entry)] [m (string-length extension)])
                (and (fx> n m) (string=? (substring entry (fx- n m) n) extension)
                     (substring entry 0 (fx- n m)))))
            extensions))

  ;; A file that only a library includes, or a script, names no library;
  ;; one path under two extensions is one name. A linked folder is not
  ;; followed, since a link may lead back up.
  ;; .chezscheme.sls ends in .sls too, so longer extensions are tried first.
  (define (library-files root)
    (define extensions (sort (lambda (a b) (fx> (string-length a) (string-length b))) (source-extensions)))
    (let walk ([folder root] [prefix '()] [files '()])
      (fold-left
        (lambda (files entry)
          (let ([path (string-append folder "/" entry)])
            (cond
              [(string-prefix? "." entry) files]
              [(file-directory? path #f) (walk path (append prefix (list (string->symbol entry))) files)]
              [(strip-extension entry extensions)
               => (lambda (base)
                    (let ([name (append prefix (list (string->symbol base)))])
                      (if (and (not (assoc name files)) (library-file? path))
                          (cons (cons name path) files)
                          files)))]
              [else files])))
        files
        (if (file-directory? folder) (sort string<? (directory-list folder)) '()))))

  (define (tuna-file? path)
    (and (file-exists? path)
         (call-with-input-file path (lambda (p) (equal? (get-string-n p 6) "#!tuna")))))

  (define (read-word p)
    (let loop ([chars '()])
      (let ([c (peek-char p)])
        (if (or (eof-object? c) (char-whitespace? c) (memv c '(#\( #\) #\[ #\] #\;)))
            (list->string (reverse chars))
            (begin (read-char p) (loop (cons c chars)))))))

  (define (skip-block-comment p)
    (let loop ([depth 1])
      (let ([c (read-char p)])
        (cond
          [(eof-object? c) #f]
          [(and (char=? c #\|) (eqv? (peek-char p) #\#)) (read-char p) (or (fx= depth 1) (loop (fx- depth 1)))]
          [(and (char=? c #\#) (eqv? (peek-char p) #\|)) (read-char p) (loop (fx+ depth 1))]
          [else (loop depth)]))))

  ;; Chez's reader refuses #!tuna, so the start is read by hand. Chez's own
  ;; directives, such as #!r6rs, may come before the library form, and a
  ;; line starting #!/ or #!  makes the file a script.
  (define (library-file? path)
    (guard (c [(i/o-error? c) #f] [(i/o-decoding-error? c) #f])
      (call-with-input-file path
        (lambda (p)
          (let loop ()
            (let ([c (peek-char p)])
              (cond
                [(eof-object? c) #f]
                [(char-whitespace? c) (read-char p) (loop)]
                [(char=? c #\;) (get-line p) (loop)]
                [(memv c '(#\( #\[))
                 (read-char p)
                 (let skip ()
                   (let ([c (peek-char p)])
                     (if (and (char? c) (char-whitespace? c)) (begin (read-char p) (skip)) #f)))
                 (string=? (read-word p) "library")]
                [(char=? c #\#)
                 (read-char p)
                 (case (peek-char p)
                   [(#\|) (read-char p) (and (skip-block-comment p) (loop))]
                   [(#\!)
                    (read-char p)
                    (if (memv (peek-char p) '(#\/ #\space))
                        (begin (get-line p) (loop))
                        (if (member (read-word p) '("r6rs" "chezscheme" "fold-case" "no-fold-case"))
                            (loop)
                            #t))]
                   [else #f])]
                [else #f])))))))

  ;; Names Tuna, chez-lang or Chez itself answer for, or the owners' names,
  ;; are never looked up in an installed root, so a file holding one would
  ;; be silently passed over.
  (define (reserved-library-name? name)
    (or (member name '((init) (repl)))
        (memq (car name) '(tuna chez-lang csv7 r6rs rnrs chezscheme scheme)))))
