(library (tuna plugin-manager)
  (export
    start-plugins!
    plugin-root
    install-missing-plugin!
    plugin-roots
    read-configuration-lines!
    read-repl-line!
    read-configuration-line!
    plugin-line?
    index-module?
    install-plugin!
    update-plugin!
    remove-plugin!
    remove-unused-plugins!
    installed-plugins
    plugin-commit
    module-plugin-source)
  (import (chezscheme) (tuna process) (tuna files)
          (only (tuna core changes) check-main-thread on-main-thread? find-owner)
          (only (tuna core definitions) report-safely report-warning)
          (only (tuna core modules) import-spec-library loaded-modules
                module-loaded? module-generation unload-module! reload-module! normal-path)
          (only (tuna core main-thread) post-task! suspend))

  (define tuna-program #f)
  (define home #f)
  (define configuration-file #f)
  (define lib-root #f)
  (define library-root #f)
  (define plugins-root #f)

  (define (start-plugins! program home-folder configuration lib library plugins)
    (set! tuna-program program)
    (set! home home-folder)
    (set! configuration-file configuration)
    (set! lib-root lib)
    (set! library-root library)
    (set! plugins-root plugins))

  (define (clause? c)
    (and (list? c) (fx= (length c) 2) (memq (car c) '(git commit branch dir local)) (string? (cadr c))))

  ;; An id names a folder in plugins/, beside the .<id>.new and .<id>.old
  ;; folders an install moves aside.
  (define (plugin-id? x)
    (and (symbol? x)
         (let ([s (symbol->string x)])
           (and (fx> (string-length s) 0)
                (not (char=? (string-ref s 0) #\.))
                (not (memv #\/ (string->list s)))))))

  (define (config-clause? c)
    (and (pair? c) (eq? (car c) 'config) (list? c)))

  (define (plugin-line? x)
    (and (list? x) (fx>= (length x) 2) (eq? (car x) 'use-plugin) (plugin-id? (cadr x))
         (let loop ([cs (cddr x)])
           (or (null? cs)
               (and (null? (cdr cs)) (config-clause? (car cs)))
               (and (clause? (car cs)) (loop (cdr cs)))))))

  (define (line-id line) (cadr line))

  (define (line-clause line key)
    (let ([c (assq key (cddr line))])
      (and c (cadr c))))

  (define (line-source? line)
    (and (or (line-clause line 'git) (line-clause line 'local)) #t))

  (define (line-with-commit line commit)
    (let-values ([(config clauses) (partition config-clause? (cddr line))])
      `(use-plugin ,(line-id line)
         ,@(remp (lambda (c) (eq? (car c) 'commit)) clauses)
         ,@(if commit `((commit ,commit)) '())
         ,@config)))

  (define (local-folder folder) (normal-path (expand-home folder home)))

  (define (source-extensions) (map car (library-extensions)))

  (define (module-file root name)
    (let ([base (format "~a/~a~{/~a~}" root (car name) (cdr name))])
      (find file-exists? (map (lambda (extension) (string-append base extension)) (source-extensions)))))

  (define (lib-module? name) (and (module-file lib-root name) #t))

  ;; Chez asks for a module while it expands the import a line stands for,
  ;; before the line runs, so lines are read as data first.
  (define configuration-lines '())
  (define repl-lines '())

  (define (configuration-line id)
    (find (lambda (line) (eq? (line-id line) id)) configuration-lines))

  (define (repl-line id)
    (find (lambda (line) (eq? (line-id line) id)) repl-lines))

  (define (configuration-text)
    (if (file-exists? configuration-file) (read-text-file configuration-file) ""))

  ;; A read error ends the configuration where it stands, as when it runs.
  (define (configuration-forms)
    (let ([p (open-string-input-port (configuration-text))])
      (let loop ([forms '()])
        (let ([form (guard (c [(lexical-violation? c) (eof-object)]) (read p))])
          (if (eof-object? form)
              (reverse forms)
              (loop (cons form forms)))))))

  (define (read-configuration-lines!)
    (set! configuration-lines
      (let loop ([forms (configuration-forms)] [lines '()])
        (cond
          [(null? forms) (reverse lines)]
          [(not (plugin-line? (car forms))) (loop (cdr forms) lines)]
          [(find (lambda (line) (eq? (line-id line) (line-id (car forms)))) lines)
           (report-safely
             (condition (make-error) (make-who-condition 'use-plugin)
               (make-message-condition (format "a second line for ~a" (line-id (car forms))))))
           (loop (cdr forms) lines)]
          [else (loop (cdr forms) (cons (car forms) lines))]))))

  (define (read-repl-line! form)
    (when (plugin-line? form)
      (set! repl-lines (cons form (remp (lambda (line) (eq? (line-id line) (line-id form))) repl-lines)))))

  (define (set-configuration-line! id line)
    (set! configuration-lines
      (cond
        [(not line) (remp (lambda (known) (eq? (line-id known) id)) configuration-lines)]
        [(configuration-line id)
         (map (lambda (known) (if (eq? (line-id known) id) line known)) configuration-lines)]
        [else (append configuration-lines (list line))])))

  (define (read-configuration-line! form)
    (when (plugin-line? form)
      (set-configuration-line! (line-id form) form)))

  (define-record-type install-source
    (nongenerative)
    (sealed #t)
    (fields git dir branch local))

  (define (plugin-folder id) (format "~a/~a" plugins-root id))
  (define (install-source-file id) (format "~a/~a.installed" plugins-root id))

  (define (read-install-source id)
    (let ([file (install-source-file id)] [folder (plugin-folder id)])
      (cond
        [(file-exists? file)
         (let* ([data (guard (c [(i/o-error? c) '()]) (call-with-input-file file read))]
                [clauses (if (list? data) (filter clause? data) '())]
                [clause (lambda (key) (let ([c (assq key clauses)]) (and c (cadr c))))]
                [found (make-install-source (clause 'git) (clause 'dir) (clause 'branch) (clause 'local))])
           (and (or (install-source-local found) (file-directory? folder)) found))]
        [(file-directory? folder) (make-install-source #f #f #f #f)]
        [else #f])))

  ;; Other threads look up plain libraries that plugins hold for workers;
  ;; they read the disk, since the cache belongs to the main thread.
  (define install-sources (make-eq-hashtable))

  (define (installed-source id)
    (if (on-main-thread?)
        (let ([known (hashtable-ref install-sources id 'unread)])
          (if (eq? known 'unread)
              (let ([found (read-install-source id)])
                (hashtable-set! install-sources id found)
                found)
              known))
        (read-install-source id)))

  (define (install-root id found)
    (or (install-source-local found)
        (let ([dir (install-source-dir found)])
          (if dir (string-append (plugin-folder id) "/" dir) (plugin-folder id)))))

  (define (write-file-atomically! path text)
    (let ([temporary (string-append path ".new")])
      (call-with-port
        (open-file-output-port temporary (file-options no-fail) (buffer-mode block)
          (make-transcoder (utf-8-codec)))
        (lambda (p) (put-string p text)))
      (rename-file temporary path)))

  (define (write-install-source! id clauses)
    (make-folders! plugins-root)
    (write-file-atomically! (install-source-file id) (format "~s\n" clauses))
    (hashtable-delete! install-sources id))

  (define (installed-ids)
    (if (file-directory? plugins-root)
        (filter installed-source
          (fold-left
            (lambda (ids entry)
              (let ([id (cond
                          [(string=? (path-extension entry) "installed") (string->symbol (path-root entry))]
                          [(and (not (string-prefix? "." entry))
                                (file-directory? (string-append plugins-root "/" entry)))
                           (string->symbol entry)]
                          [else #f])])
                (if (and (plugin-id? id) (not (memq id ids))) (cons id ids) ids)))
            '()
            (directory-list plugins-root)))
        '()))

  (define (installed-plugins)
    (let* ([ids (installed-ids)]
           [named (filter (lambda (id) (memq id ids)) (map line-id configuration-lines))])
      (append named
        (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
              (remp (lambda (id) (memq id named)) ids)))))

  (define (plugin-roots)
    (map (lambda (id) (cons id (install-root id (installed-source id)))) (installed-ids)))

  ;; Tuna checks out detached, so HEAD holds the commit.
  (define (checked-out-commit folder)
    (let ([head (string-append folder "/.git/HEAD")])
      (and (file-exists? head)
           (let ([line (call-with-input-file head get-line)])
             (and (string? line)
                  (fx>= (string-length line) 40)
                  (for-all (lambda (c) (memv c (string->list "0123456789abcdef"))) (string->list line))
                  line)))))

  (define (plugin-commit id)
    (unless (plugin-id? id) (assertion-violation 'plugin-commit "not a plugin id" id))
    (let ([found (installed-source id)])
      (and found (not (install-source-local found)) (checked-out-commit (plugin-folder id)))))

  (define (git-address url) (expand-home url home))

  (define (installed-from? line id found)
    (let ([local (line-clause line 'local)])
      (if local
          (equal? (install-source-local found) (local-folder local))
          (and (equal? (install-source-git found) (git-address (line-clause line 'git)))
               (equal? (install-source-dir found) (line-clause line 'dir))
               (let ([commit (line-clause line 'commit)])
                 (if commit
                     (let ([head (checked-out-commit (plugin-folder id))])
                       (and head (string-prefix? commit head)))
                     (equal? (install-source-branch found) (line-clause line 'branch))))))))

  ;; An index's lines are needed before its module compiles, and a local
  ;; index may be edited, so they are read from its file when it changes.
  (define index-lines-read (make-eq-hashtable))

  (define (index-lines id)
    (let* ([found (installed-source id)]
           [file (and found (module-file (install-root id found) (list id)))])
      (if file
          (let ([time (file-modification-time file)] [known (hashtable-ref index-lines-read id #f)])
            (if (and known (time=? (car known) time))
                (cdr known)
                (let ([lines (read-index-lines file)])
                  (hashtable-set! index-lines-read id (cons time lines))
                  lines)))
          '())))

  (define (index-form? form)
    (and (pair? form) (eq? (car form) 'plugin) (plugin-line? (cons 'use-plugin (cdr form)))))

  (define (read-index-lines file)
    (guard (c [(i/o-error? c) '()])
      (call-with-input-file file
        (lambda (p)
          (let ([language (get-line p)])
            (if (and (string? language) (string-prefix? "#!tuna" language))
                (let loop ([lines '()] [imports? #t])
                  (let ([form (read p)])
                    (cond
                      [(eof-object? form) (reverse lines)]
                      [(and imports? (pair? form) (eq? (car form) 'import)) (loop lines #t)]
                      [(index-form? form) (loop (cons (cons 'use-plugin (cdr form)) lines) #f)]
                      [else '()])))
                '()))))))

  (define (index-module? name)
    (and (null? (cdr name))
         (not (lib-module? name))
         (pair? (index-lines (car name)))))

  (define (index-line id)
    (let loop ([ids (installed-plugins)])
      (and (pair? ids)
           (or (and (not (eq? (car ids) id))
                    (find (lambda (line) (eq? (line-id line) id)) (index-lines (car ids))))
               (loop (cdr ids))))))

  (define (resolve-line line)
    (if (line-source? line)
        line
        (let ([from (index-line (line-id line))])
          (and from
               (let* ([own (cddr line)]
                      [pin? (lambda (c) (memq (car c) '(commit branch)))]
                      [given (if (exists pin? own) (remp pin? (cddr from)) (cddr from))])
                 `(use-plugin ,(line-id line) ,@own ,@given))))))

  (define (known-line id)
    (let ([line (or (configuration-line id) (repl-line id))])
      (if line (resolve-line line) (index-line id))))

  (define (module-plugin-source name)
    (let* ([id (car name)] [found (and (plugin-id? id) (installed-source id))])
      (cond
        [(lib-module? name) 'user]
        [(and found (module-file (install-root id found) name))
         (or (install-source-git found) (install-source-local found) (plugin-folder id))]
        [else 'tuna])))

  (define (plugin-modules id)
    (filter (lambda (name) (and (eq? (car name) id) (not (lib-module? name)))) (loaded-modules)))

  (define found-plugins (make-eq-hashtable))

  (define (plugin-root name install?)
    (let ([id (car name)])
      (and (plugin-id? id)
           (if install?
               (let ([root (checked-root id)])
                 (when root (hashtable-set! found-plugins id #t))
                 root)
               (let ([found (installed-source id)])
                 (and found (install-root id found)))))))

  ;; A plugin whose modules are loaded keeps its files until it is updated
  ;; or Tuna starts again, so that a lookup never changes code that runs.
  (define (checked-root id)
    (let ([line (configuration-line id)] [found (installed-source id)])
      (if (and line (null? (plugin-modules id)))
          (let ([resolved (resolve-line line)])
            (cond
              [(and resolved (if found (not (installed-from? resolved id found)) (line-source? line)))
               (let* ([replaced? (file-exists? (plugin-folder id) #f)]
                      [root (install-line! 'import resolved)])
                 (when replaced?
                   (report-lookup-warning "replaced ~a, installed from another source or commit than its line's"
                     (plugin-folder id)))
                 root)]
              [(and found (not resolved) (module-file library-root (list id)))
               (when (file-exists? (plugin-folder id) #f)
                 (report-lookup-warning "removed ~a: its line finds the plugin in Tuna's own library"
                   (plugin-folder id)))
               (uninstall! id)
               #f]
              [else (and found (install-root id found))]))
          (and found (install-root id found)))))

  ;; plugins/ is Tuna's to manage, but a copy may have been put there by
  ;; hand, so a lookup never replaces or removes one silently.
  (define (report-lookup-warning message folder)
    (report-warning 'import (format message folder)))

  ;; Installing over an installed plugin would replace the files a running
  ;; module came from.
  (define (install-missing-plugin! name)
    (let ([id (car name)])
      (and (plugin-id? id)
           (not (installed-source id))
           (let ([line (known-line id)])
             (unless line
               (if (or (configuration-line id) (repl-line id))
                   (errorf 'import
                     "the line for ~a has no source: give it a git or local clause, or use an index that names it"
                     id)
                   (errorf 'import "no plugin line for ~s: add (use-plugin ~a (git \"...\")) to init.ss" name id)))
             (let ([root (install-line! 'import line)])
               (hashtable-set! found-plugins id #t)
               root)))))

  (define (delete-tree path)
    (cond
      [(file-directory? path #f)
       (for-each (lambda (entry) (delete-tree (string-append path "/" entry))) (directory-list path))
       (delete-directory path)]
      [(file-exists? path #f) (delete-file path)]))

  (define (last-line text)
    (let loop ([lines '()] [p (open-string-input-port text)])
      (let ([line (get-line p)])
        (if (eof-object? line)
            (or (find (lambda (line) (not (string=? line ""))) lines) "")
            (loop (cons line lines) p)))))

  ;; In a session of its own git has no terminal, so ssh fails where it
  ;; would ask for a passphrase or a host key: while an import installs,
  ;; the main thread waits for git.
  (define (run-git arguments)
    (run-program "setsid" (cons* "-w" "env" "GIT_TERMINAL_PROMPT=0" "git" arguments)))

  (define (git who url . arguments)
    (let-values ([(status output) (run-git arguments)])
      (unless (eqv? status 0)
        (errorf who "git failed for ~a: ~a" url (last-line output)))))

  (define (check-out! who url folder commit branch)
    (let ([revision (cond [commit commit] [branch (string-append "origin/" branch)] [else "origin/HEAD"])])
      (let-values ([(status output)
                    (run-git (list "-C" folder "rev-parse" "--quiet" "--verify"
                                   (string-append revision "^{commit}")))])
        (unless (eqv? status 0)
          (cond
            [commit (errorf who "commit ~a not found in ~a" commit url)]
            [branch (errorf who "branch ~a not found in ~a" branch url)]
            [else (errorf who "~a has no default branch" url)])))
      (git who url "-C" folder "checkout" "--quiet" "--detach" revision)
      (checked-out-commit folder)))

  ;; Runs on any thread: it touches only the folder it fills.
  (define (clone! who url commit branch target)
    (delete-tree target)
    (guard (c [#t (delete-tree target) (raise c)])
      (git who url "clone" "--quiet" "--no-checkout" url target)
      (check-out! who url target commit branch)))

  (define (build-log id) (format "~a/.cache/tuna/builds/~a.log" home id))

  ;; One install or update may build twice, when an update goes back, so
  ;; the log is started once for it and each build adds to it.
  (define (start-build-log! id)
    (delete-file (build-log id) #f))

  ;; Third-party code, Scheme included, comes in as submodules, so they are
  ;; fetched for every plugin. The build runs in a process of its own, so
  ;; one that crashes, loops, exits or changes its directory leaves Tuna
  ;; running; it has no terminal, as git has none.
  (define (build! who id url folder root)
    (git who url "-C" folder "submodule" "--quiet" "update" "--init" "--recursive")
    (when (file-exists? (string-append root "/build.ss"))
      (let-values ([(status output)
                    (run-program "setsid"
                      (list "-w" "env" "-C" root "GIT_TERMINAL_PROMPT=0" tuna-program "--script" "build.ss"))])
        (let ([log (build-log id)])
          (make-folders! (path-parent log))
          (call-with-output-file log
            (lambda (p) (fprintf p "build of ~a, status ~a\n~a" (checked-out-commit folder) status output))
            'append)
          (unless (eqv? status 0)
            (errorf who "the build of ~a failed with status ~a: ~a (output in ~a)"
              id status (last-line output) log))))))

  (define (temporary-folder id) (format "~a/.~a.new" plugins-root id))

  (define (git-clauses url dir branch)
    `((git ,url) ,@(if dir `((dir ,dir)) '()) ,@(if branch `((branch ,branch)) '())))

  (define (line-git-clauses line)
    (git-clauses (git-address (line-clause line 'git)) (line-clause line 'dir) (line-clause line 'branch)))

  (define (source-clauses found)
    (git-clauses (install-source-git found) (install-source-dir found) (install-source-branch found)))

  (define (check-main-module who id root)
    (unless (module-file root (list id))
      (errorf who "plugin ~a holds no module (~a)" id id)))

  ;; Other threads may look up the plugin's plain libraries meanwhile, so
  ;; the old folder is moved aside, not deleted, before the new one comes.
  ;; The build runs in the plugin's own folder, since what it makes may
  ;; record its path, so the old folder is kept until the build succeeds.
  (define (replace-folder! who line temporary run-build)
    (let* ([id (line-id line)] [dir (line-clause line 'dir)]
           [folder (plugin-folder id)] [old (format "~a/.~a.old" plugins-root id)])
      (delete-tree old)
      (when (file-exists? folder #f) (rename-file folder old))
      (rename-file temporary folder)
      (start-build-log! id)
      (guard (c [#t (delete-tree folder)
                    (when (file-exists? old #f) (rename-file old folder))
                    (raise c)])
        (run-build
          (lambda ()
            (build! who id (git-address (line-clause line 'git)) folder
              (if dir (string-append folder "/" dir) folder)))))
      (delete-tree old)))

  (define (finish-install! who line temporary run-build)
    (let* ([id (line-id line)] [dir (line-clause line 'dir)])
      (guard (c [#t (delete-tree temporary) (raise c)])
        (check-main-module who id (if dir (string-append temporary "/" dir) temporary)))
      (replace-folder! who line temporary run-build)
      (write-install-source! id (line-git-clauses line))
      (hashtable-delete! index-lines-read id)
      (install-root id (installed-source id))))

  (define (install-local! who id folder)
    (check-main-module who id folder)
    (delete-tree (plugin-folder id))
    (write-install-source! id `((local ,folder)))
    (hashtable-delete! index-lines-read id)
    folder)

  ;; While Chez expands an import, git runs on the main thread: the
  ;; expander cannot pause.
  (define (install-line! who line)
    (check-not-fetching who (line-id line))
    (let ([id (line-id line)] [local (line-clause line 'local)])
      (if local
          (install-local! who id (local-folder local))
          (let ([url (git-address (line-clause line 'git))] [temporary (temporary-folder id)])
            (make-folders! plugins-root)
            (clone! who url (line-clause line 'commit) (line-clause line 'branch) temporary)
            (finish-install! who line temporary (lambda (build) (build)))))))

  ;; While git runs for a plugin, its task pauses and the main thread goes
  ;; on, so another install of the same plugin could start and share its
  ;; folders.
  (define fetching '())

  (define (check-not-fetching who id)
    (when (memq id fetching)
      (assertion-violation who "git is running for the plugin" id)))

  ;; A quit ends the task while git may still fill the plugin's folders,
  ;; so the id stays taken until both git and the task are done. git's end
  ;; is posted before the resume, so it is counted first when no quit came,
  ;; and on behalf of (tuna), so that it runs whichever module is unloaded
  ;; meanwhile.
  (define (call-paused who id thunk)
    (check-not-fetching who id)
    (set! fetching (cons id fetching))
    (let ([forked? #f] [running 2])
      (define (done!)
        (set! running (fx- running 1))
        (when (fx= running 0)
          (set! fetching (remq id fetching))))
      (let ([result (guard (c [#t (if forked? (done!) (set! fetching (remq id fetching))) (raise c)])
                      (suspend
                        (lambda (resume)
                          (set! forked? #t)
                          (fork-thread
                            (lambda ()
                              (let ([result (guard (c [#t (lambda () (raise c))])
                                              (let ([v (thunk)]) (lambda () v)))])
                                (post-task! done! (find-owner '(tuna)) #f)
                                (resume result)))))))])
        (done!)
        result)))

  (define (install-paused! who line)
    (let ([id (line-id line)] [local (line-clause line 'local)])
      (if local
          (begin (install-local! who id (local-folder local)) #f)
          (let ([url (git-address (line-clause line 'git))] [temporary (temporary-folder id)])
            (make-folders! plugins-root)
            (call-paused who id
              (lambda () (clone! who url (line-clause line 'commit) (line-clause line 'branch) temporary)))
            (finish-install! who line temporary (lambda (build) (call-paused who id build)))
            (checked-out-commit (plugin-folder id))))))

  ;; Positions are in characters, so they index the text as read.
  (define-record-type span
    (nongenerative)
    (sealed #t)
    (fields start end datum annotation))

  (define (top-level-spans text)
    (let ([p (open-string-input-port text)]
          [sfd (make-source-file-descriptor configuration-file (open-bytevector-input-port (string->utf8 text)))])
      (let loop ([position 0] [spans '()])
        (let-values ([(form end) (get-datum/annotations p sfd position)])
          (cond
            [(eof-object? form) (reverse spans)]
            [(annotation? form)
             (let ([source (annotation-source form)])
               (loop end (cons (make-span (source-object-bfp source) (source-object-efp source)
                                 (annotation-stripped form) form)
                               spans)))]
            [else (loop end spans)])))))

  (define (imports-plugins? form)
    (and (list? form) (pair? form) (eq? (car form) 'import)
         (exists (lambda (spec) (equal? (import-spec-library spec) '(tuna plugins))) (cdr form))))

  (define (insertion-point who spans)
    (let ([lines (filter (lambda (s) (plugin-line? (span-datum s))) spans)])
      (cond
        [(pair? lines) (span-end (car (last-pair lines)))]
        [(find (lambda (s) (imports-plugins? (span-datum s))) spans) => span-end]
        [else (assertion-violation who "the configuration does not import (tuna plugins)")])))

  (define (line-span id spans)
    (find (lambda (s) (and (plugin-line? (span-datum s)) (eq? (line-id (span-datum s)) id))) spans))

  (define (write-configuration! text)
    (make-folders! (path-parent configuration-file))
    (write-file-atomically! configuration-file text))

  (define (line-text line) (format "~s" line))

  (define (text-with text start end new)
    (string-append (substring text 0 start) new (substring text end (string-length text))))

  (define (insert-configuration-line! who line)
    (let* ([text (configuration-text)] [at (insertion-point who (top-level-spans text))])
      (write-configuration! (text-with text at at (string-append "\n" (line-text line))))
      (set-configuration-line! (line-id line) line)))

  ;; Only the commit's text changes, so the rest of the line, its comments
  ;; and its config clause's code stay as written.
  (define (text-with-commit text line commit)
    (let* ([parts (cdr (annotation-expression line))]
           [old (find (lambda (c) (eq? (car (annotation-stripped c)) 'commit)) (cdr parts))])
      (if old
          (let ([s (annotation-source (cadr (annotation-expression old)))])
            (text-with text (source-object-bfp s) (source-object-efp s) (format "~s" commit)))
          (let ([at (source-object-efp
                      (annotation-source
                        (car (last-pair (remp (lambda (c) (config-clause? (annotation-stripped c))) parts)))))])
            (text-with text at at (format " (commit ~s)" commit))))))

  ;; The line as the file holds it now, which may have been edited since
  ;; the configuration last ran.
  (define (write-configuration-commit! who line commit)
    (let* ([id (line-id line)] [text (configuration-text)] [span (line-span id (top-level-spans text))])
      (cond
        [span
         (write-configuration! (text-with-commit text (span-annotation span) commit))
         (set-configuration-line! id (line-with-commit (span-datum span) commit))]
        [else (insert-configuration-line! who (line-with-commit line commit))])))

  ;; Other tasks may have edited the file while this one paused, so only
  ;; the plugin's own line is touched, in the text as it is now. With no
  ;; replacement, the newline insert-configuration-line! put before the
  ;; line goes with it.
  (define (replace-line-text! id replacement)
    (let* ([text (configuration-text)] [span (line-span id (top-level-spans text))])
      (when span
        (write-configuration!
          (if replacement
              (text-with text (span-start span) (span-end span) replacement)
              (let ([start (span-start span)])
                (text-with text
                  (if (and (fx> start 0) (char=? (string-ref text (fx- start 1)) #\newline))
                      (fx- start 1)
                      start)
                  (span-end span) "")))))))

  ;; Commented out rather than deleted, so that a config clause's code is
  ;; kept for the user.
  (define (comment-out-configuration-line! id)
    (let* ([text (configuration-text)] [span (line-span id (top-level-spans text))])
      (when span
        (write-configuration! (text-with text (span-start span) (span-start span) "#;"))))
    (set-configuration-line! id #f))

  (define (install-plugin! line)
    (unless (plugin-line? line)
      (assertion-violation 'install-plugin! "not a use-plugin line" line))
    (check-main-thread 'install-plugin!)
    (let ([id (line-id line)])
      (when (configuration-line id)
        (assertion-violation 'install-plugin! "the configuration has a line for the plugin" id))
      (let ([source (or (resolve-line line)
                        (assertion-violation 'install-plugin! "no source for the plugin" id))])
        (insertion-point 'install-plugin! (top-level-spans (configuration-text)))
        (let ([commit (install-paused! 'install-plugin! source)])
          (insert-configuration-line! 'install-plugin! (line-with-commit line commit))))))

  ;; A module reloaded as an importer of an earlier one has run its body
  ;; again already.
  (define (reload-plugin-modules! id)
    (let* ([names (plugin-modules id)] [generations (map module-generation names)])
      (let loop ([names names] [generations generations])
        (cond
          [(null? names) #t]
          [(or (not (module-loaded? (car names)))
               (not (eqv? (module-generation (car names)) (car generations)))
               (reload-module! (car names)))
           (loop (cdr names) (cdr generations))]
          [else #f]))))

  (define (fetch! who url folder commit branch)
    (git who url "-C" folder "remote" "set-url" "origin" url)
    (git who url "-C" folder "fetch" "--quiet" "origin")
    (check-out! who url folder commit branch))

  (define update-plugin!
    (case-lambda
      [(id) (update-plugin! id #f)]
      [(id commit)
       (unless (plugin-id? id) (assertion-violation 'update-plugin! "not a plugin id" id))
       (unless (or (not commit) (string? commit)) (assertion-violation 'update-plugin! "not a commit" commit))
       (check-main-thread 'update-plugin!)
       (let ([found (or (installed-source id) (assertion-violation 'update-plugin! "not installed" id))])
         (when (install-source-local found)
           (assertion-violation 'update-plugin! "a local plugin is not fetched" id))
         (let* ([text (configuration-text)]
                [span (line-span id (top-level-spans text))]
                [line (cond [span (span-datum span)] [(repl-line id)] [else `(use-plugin ,id)])]
                [source (or (resolve-line line)
                            (and (install-source-git found)
                                 `(use-plugin ,id ,@(source-clauses found)))
                            (assertion-violation 'update-plugin! "no source for the plugin" id))]
                [url (git-address (line-clause source 'git))]
                [folder (plugin-folder id)]
                [dir (line-clause source 'dir)]
                [root (if dir (string-append folder "/" dir) folder)]
                [previous-commit (checked-out-commit folder)]
                [previous-line-text (and span (substring text (span-start span) (span-end span)))]
                [previous-line (configuration-line id)])
           (define (go-back!)
             (when (install-source-git found)
               (write-install-source! id (source-clauses found)))
             (call-paused 'update-plugin! id
               (lambda ()
                 (when (install-source-git found)
                   (git 'update-plugin! url "-C" folder "remote" "set-url" "origin" (install-source-git found)))
                 (when previous-commit
                   (git 'update-plugin! url "-C" folder "checkout" "--quiet" "--detach" previous-commit))))
             ;; The update has failed already, so a failed build of the
             ;; previous commit is only reported.
             (when previous-commit
               (guard (c [#t (report-safely c)])
                 (call-paused 'update-plugin! id (lambda () (build! 'update-plugin! id url folder root))))))
           (unless span
             (insertion-point 'update-plugin! (top-level-spans text)))
           (let ([new (call-paused 'update-plugin! id
                        (lambda ()
                          (fetch! 'update-plugin! url folder commit (and (not commit) (line-clause source 'branch)))))])
             (start-build-log! id)
             (guard (c [#t (go-back!) (raise c)])
               (check-main-module 'update-plugin! id root)
               (call-paused 'update-plugin! id (lambda () (build! 'update-plugin! id url folder root))))
             (write-install-source! id (line-git-clauses source))
             (hashtable-delete! index-lines-read id)
             (write-configuration-commit! 'update-plugin! line new)
             (unless (reload-plugin-modules! id)
               (replace-line-text! id previous-line-text)
               (set-configuration-line! id previous-line)
               (go-back!)
               (reload-plugin-modules! id)
               (void)))))]))

  (define (uninstall! id)
    (delete-tree (plugin-folder id))
    (delete-tree (install-source-file id))
    (hashtable-delete! install-sources id)
    (hashtable-delete! index-lines-read id))

  (define (remove-plugin! id)
    (unless (plugin-id? id) (assertion-violation 'remove-plugin! "not a plugin id" id))
    (check-main-thread 'remove-plugin!)
    (unless (or (installed-source id) (configuration-line id))
      (assertion-violation 'remove-plugin! "not installed" id))
    (for-each (lambda (name) (when (module-loaded? name) (unload-module! name)))
              (reverse (plugin-modules id)))
    (comment-out-configuration-line! id)
    (uninstall! id))

  (define (remove-unused-plugins!)
    (check-main-thread 'remove-unused-plugins!)
    (for-each
      (lambda (id)
        (unless (or (configuration-line id) (hashtable-contains? found-plugins id))
          (uninstall! id)))
      (installed-plugins))))
