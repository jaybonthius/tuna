#!tuna
(import (processes))

(define-hook finders
  "Called with a folder ending in /; each entry returns the project holding it, or #f, and projects:find takes the first project returned.")

(define-option merge-submodules? #t boolean?
  "Whether a git submodule belongs to the project of the repository holding it, for finding and for listing.")

(define-option extra-root-markers '()
  (lambda (v)
    (and (list? v)
         (for-all (lambda (name)
                    (and (string? name) (fx> (string-length name) 0) (not (member name '("." "..")))
                         (not (memv #\/ (string->list name)))))
                  v)))
  "File names, beside the version-control ones, whose presence makes a folder a project's root.")

(define-option ignores
  (list "SCCS/" "RCS/" "CVS/" "MCVS/" ".src/" ".svn/" ".git/" ".hg/" ".bzr/" "_MTN/" "_darcs/" "{arch}/" ".repo/" ".jj/"
        ".#*" "*.o" "*~" "*.bin" "*.lbin" "*.so" "*.a" "*.ln" "*.blg" "*.bbl" "*.elc" "*.lof" "*.glo" "*.idx" "*.lot"
        "*.fmt" "*.tfm" "*.class" "*.fas" "*.lib" "*.mem" "*.x86f" "*.sparcf" "*.dfsl" "*.pfsl" "*.d64fsl" "*.p64fsl"
        "*.lx64fsl" "*.lx32fsl" "*.dx64fsl" "*.dx32fsl" "*.fx64fsl" "*.fx32fsl" "*.sx64fsl" "*.sx32fsl" "*.wx64fsl"
        "*.wx32fsl" "*.fasl" "*.ufsl" "*.fsl" "*.dxl" "*.lo" "*.la" "*.gmo" "*.mo" "*.toc" "*.aux" "*.cp" "*.fn" "*.ky"
        "*.pg" "*.tp" "*.vr" "*.cps" "*.fns" "*.kys" "*.pgs" "*.tps" "*.vrs" "*.pyc" "*.pyo")
  (lambda (v) (and (list? v) (for-all (lambda (pattern) (and (string? pattern) (fx> (string-length pattern) 0))) v)))
  "What projects:list-with-find leaves out: find glob patterns, a folder's ending in /, one anchored at the root starting with ./.")

(define-record-type (%project %make-project project?)
  (sealed #t)
  (fields root lister))

(module %internals (absolute? with-slash starts-with? version-control-markers search backend merged check-lister
                    git-listing find-listing)

  (define (absolute? v) (and (string? v) (fx> (string-length v) 0) (char=? (string-ref v 0) #\/)))

  (define (with-slash folder)
    (let ([n (string-length folder)])
      (if (char=? (string-ref folder (fx- n 1)) #\/) folder (string-append folder "/"))))

  (define (starts-with? s part at)
    (let ([n (string-length part)])
      (and (fx<= (fx+ at n) (string-length s))
           (let loop ([i 0])
             (or (fx= i n)
                 (and (char=? (string-ref s (fx+ at i)) (string-ref part i)) (loop (fx+ i 1))))))))

  (define (index-of s part from)
    (let loop ([i from])
      (and (fx<= (fx+ i (string-length part)) (string-length s))
           (if (starts-with? s part i) i (loop (fx+ i 1))))))

  (define (parent folder)
    (let loop ([i (fx- (string-length folder) 2)])
      (cond
        [(fx< i 0) "/"]
        [(char=? (string-ref folder i) #\/) (substring folder 0 (fx+ i 1))]
        [else (loop (fx- i 1))])))

  (define (home)
    (let ([h (getenv "HOME")])
      (if (absolute? h) (with-slash h) "/")))

  ;; A repository of / or /home would otherwise hold every folder in the
  ;; home folder, and looking in /net/ or /afs/ can mount a network folder.
  (define (walk folder found?)
    (let ([stop (home)])
      (let loop ([dir folder])
        (cond
          [(member dir '("/net/" "/afs/")) #f]
          [(found? dir) dir]
          [(or (string=? dir "/") (string=? dir stop)) #f]
          [else (loop (parent dir))]))))

  (define (holds? dir name) (file-exists? (string-append dir name) #f))

  (define version-control-markers '(".svn" ".bzr" ".git" ".hg"))

  (define (search folder markers)
    (walk folder (lambda (dir) (exists (lambda (marker) (holds? dir marker)) markers))))

  (define (backend root)
    (exists (lambda (marker) (and (holds? root marker) marker)) version-control-markers))

  ;; A worktree's .git file points into .git/worktrees/ alone, so a
  ;; worktree stays a project of its own.
  (define (gitdir-into-modules? line)
    (and (starts-with? line "gitdir: " 0)
         (let loop ([i 9])
           (and (fx<= (fx+ i 6) (string-length line))
                (or (and (starts-with? line "/.git/" i)
                         (or (starts-with? line "modules/" (fx+ i 6))
                             (and (starts-with? line "worktrees/" (fx+ i 6))
                                  (index-of line "modules/" (fx+ i 16)))))
                    (loop (fx+ i 1)))))))

  (define (submodule? root)
    (let ([git (string-append root ".git")])
      (and (not (file-directory? git))
           (let ([line (guard (c [(i/o-error? c) #f]) (call-with-input-file git get-line))])
             (and (string? line) (gitdir-into-modules? line))))))

  (define (merged root merge?)
    (let loop ([root root])
      (cond
        [(not (and merge? (submodule? root))) root]
        [(string=? root "/") #f]
        [(walk (parent root) (lambda (dir) (holds? dir ".git"))) => loop]
        [else #f])))

  (define (repository-top folder)
    (let loop ([dir folder])
      (cond
        [(holds? dir ".git") dir]
        [(string=? dir "/") folder]
        [else (loop (parent dir))])))

  (define (skip-blanks line i)
    (if (and (fx< i (string-length line)) (memv (string-ref line i) '(#\space #\tab))) (skip-blanks line (fx+ i 1)) i))

  (define (skip-spaces line i)
    (if (and (fx< i (string-length line)) (char=? (string-ref line i) #\space)) (skip-spaces line (fx+ i 1)) i))

  (define (gitmodule-path line)
    (let ([i (skip-blanks line 0)])
      (and (starts-with? line "path" i)
           (let ([i (skip-spaces line (fx+ i 4))])
             (and (fx< i (string-length line))
                  (char=? (string-ref line i) #\=)
                  (let ([i (skip-spaces line (fx+ i 1))])
                    (and (fx< i (string-length line)) (substring line i (string-length line)))))))))

  ;; .gitmodules names paths from the repository's top, which a root found
  ;; by an extra marker inside the repository is not.
  (define (gitmodule-paths folder)
    (let* ([top (repository-top folder)]
           [under (substring folder (string-length top) (string-length folder))]
           [paths (guard (c [(i/o-error? c) '()])
                    (call-with-input-file (string-append top ".gitmodules")
                      (lambda (p)
                        (let loop ([acc '()])
                          (let ([line (get-line p)])
                            (cond
                              [(eof-object? line) (reverse acc)]
                              [(gitmodule-path line) => (lambda (path) (loop (cons path acc)))]
                              [else (loop acc)]))))))])
      (fold-right
        (lambda (path acc)
          (if (and (starts-with? path under 0) (fx> (string-length path) (string-length under)))
              (cons (substring path (string-length under) (string-length path)) acc)
              acc))
        '() paths)))

  (define-record-type run (fields program arguments directory path-of))

  (define (listing runs on-files)
    (let ([left (length runs)] [stopped? #f] [started '()])
      (define (start! run)
        (let* ([found '()] [path-of (run-path-of run)] [process #f]
               [receive! (processes:line-receiver 0
                           (lambda (line end)
                             (unless (eof-object? line)
                               (let ([path (path-of line)])
                                 (when path (set! found (cons path found))))))
                           (char->integer #\nul))])
          (set! process
            (processes:start (run-program run) (run-arguments run)
              (lambda (bytes end)
                (unless stopped?
                  (receive! bytes end)
                  (unless (null? found)
                    (let ([files (list->vector (reverse found))])
                      (set! found '())
                      (on-files files)))))
              (lambda (status)
                (unless stopped?
                  (when (fixnum? status) (processes:report-error-output process 'projects:list-files))
                  (set! left (fx- left 1))
                  (when (fx= left 0) (on-files (eof-object)))))
              (processes:options [directory (run-directory run)] [separate-stderr #t])))
          (processes:close-input! process)
          (set! started (cons process started))))
      (for-each start! runs)
      (lambda ()
        (unless stopped?
          (set! stopped? #t)
          (for-each processes:stop! started)))))

  (define (check-lister who folder on-files)
    (unless (absolute? folder)
      (assertion-violation who "not an absolute path" folder))
    (unless (procedure? on-files)
      (assertion-violation who "not a procedure" on-files)))

  (define (git-runs folder prefix merge? arguments)
    (let* ([submodules (gitmodule-paths folder)]
           [left-out (let ([t (make-hashtable string-hash string=?)])
                       (for-each (lambda (path) (hashtable-set! t path #t)) submodules)
                       t)])
      (cons (make-run "git" arguments folder
              (lambda (path)
                (let ([n (string-length path)])
                  (and (fx> n 0)
                       (not (char=? (string-ref path (fx- n 1)) #\/))
                       (not (hashtable-contains? left-out path))
                       (if (string=? prefix "") path (string-append prefix path))))))
            (if merge?
                (fold-right
                  (lambda (path acc)
                    (let ([sub (string-append folder path "/")])
                      (if (file-directory? sub)
                          (append (git-runs sub (string-append prefix path "/") merge? arguments) acc)
                          acc)))
                  '() submodules)
                '()))))

  (define (version-numbers line)
    (let ([at (index-of line "git version " 0)])
      (let loop ([i (if at (fx+ at 12) (string-length line))] [n #f] [numbers '()])
        (let ([c (and (fx< i (string-length line)) (string-ref line i))])
          (cond
            [(and c (char<=? #\0 c #\9))
             (loop (fx+ i 1) (+ (* (or n 0) 10) (fx- (char->integer c) (char->integer #\0))) numbers)]
            [(and n (eqv? c #\.)) (loop (fx+ i 1) #f (cons n numbers))]
            [else (let ([numbers (reverse (if n (cons n numbers) numbers))])
                    (if (null? numbers) '(0) numbers))])))))

  (define (at-least? version minimum)
    (cond
      [(null? minimum) #t]
      [else
       (let ([v (if (null? version) 0 (car version))])
         (cond
           [(> v (car minimum)) #t]
           [(< v (car minimum)) #f]
           [else (at-least? (if (null? version) '() (cdr version)) (cdr minimum))]))]))

  ;; An older git refuses an option it does not know.
  (define (ls-files-arguments version)
    (append '("ls-files" "-z" "-c" "-o" "--exclude-standard")
            (if (at-least? version '(2 31)) '("--deduplicate") '())
            (if (at-least? version '(2 35)) '("--sparse") '())))

  (define git-version #f)

  (define (git-listing folder merge? on-files)
    (define (start-listing)
      (listing (git-runs folder "" merge? (ls-files-arguments git-version)) on-files))
    (if git-version
        (start-listing)
        (let* ([stopped? #f] [stop-listing #f] [line #f]
               [probe (processes:start "git" '("version")
                        (processes:line-receiver 0
                          (lambda (text end)
                            (unless (or line (eof-object? text))
                              (set! line text))))
                        (lambda (status)
                          (unless stopped?
                            (cond
                              [(fixnum? status)
                               (unless git-version
                                 (set! git-version (version-numbers (or line ""))))
                               (set! stop-listing (start-listing))]
                              [else (on-files (eof-object))]))))])
          (processes:close-input! probe)
          (lambda ()
            (unless stopped?
              (set! stopped? #t)
              (if stop-listing (stop-listing) (processes:stop! probe)))))))

  (define (find-pattern ignore)
    (let ([pattern (if (char=? (string-ref ignore (fx- (string-length ignore) 1)) #\/) (string-append ignore "*") ignore)])
      (if (or (starts-with? pattern "./" 0) (starts-with? pattern "*" 0)) pattern (string-append "*/" pattern))))

  (define (find-arguments patterns)
    (append '(".")
            (if (null? patterns)
                '()
                (append '("(") (cdr (apply append (map (lambda (p) (list "-o" "-path" (find-pattern p))) patterns)))
                        '(")" "-prune" "-o")))
            '("-xtype" "f" "-print0")))

  (define (find-listing folder patterns on-files)
    (listing (list (make-run "find" (find-arguments patterns) folder
                     (lambda (path)
                       (and (fx> (string-length path) 2) (starts-with? path "./" 0)
                            (substring path 2 (string-length path))))))
             on-files)))

(import %internals)

(define (find folder)
  (unless (absolute? folder)
    (assertion-violation 'projects:find "not an absolute path" folder))
  (let ([folder (with-slash folder)])
    (exists (lambda (entry)
              (let ([answer (entry folder)])
                (unless (or (not answer) (project? answer))
                  (assertion-violation 'projects:find "a finder answered neither a project nor #f" answer))
                answer))
            (hook-entries finders))))

(define (find-marked folder names)
  (unless (absolute? folder)
    (assertion-violation 'projects:find-marked "not an absolute path" folder))
  (unless (and (list? names) (for-all (lambda (n) (and (string? n) (fx> (string-length n) 0) (not (memv #\/ (string->list n))))) names))
    (assertion-violation 'projects:find-marked "not a list of file names" names))
  (search (with-slash folder) names))

(define (try-vc folder)
  (unless (absolute? folder)
    (assertion-violation 'projects:try-vc "not an absolute path" folder))
  (let* ([merge? (merge-submodules?)]
         [top (find-marked folder (append version-control-markers (extra-root-markers)))]
         [vc (and top (backend top))])
    (cond
      [(not top) #f]
      [(not vc)
       (let* ([vc-top (search top version-control-markers)]
              [vc (and vc-top (backend vc-top))])
         (make-project top (if (and (equal? vc ".git") (merged vc-top merge?)) list-with-git list-with-find)))]
      [(string=? vc ".git")
       (let ([top (merged top merge?)])
         (and top (make-project top list-with-git)))]
      [else (make-project top list-with-find)])))

(define (make-project root lister)
  (unless (absolute? root)
    (assertion-violation 'projects:make-project "not an absolute path" root))
  (unless (procedure? lister)
    (assertion-violation 'projects:make-project "not a procedure" lister))
  (%make-project (with-slash root) lister))

(define (root project)
  (unless (project? project)
    (assertion-violation 'projects:root "not a project" project))
  (%project-root project))

(define (list-files project on-files)
  (unless (project? project)
    (assertion-violation 'projects:list-files "not a project" project))
  (unless (procedure? on-files)
    (assertion-violation 'projects:list-files "not a procedure" on-files))
  (let ([stop ((%project-lister project) (%project-root project) on-files)])
    (unless (procedure? stop)
      (assertion-violation 'projects:list-files "a lister returned what is not a procedure" stop))
    stop))

(define (list-with-git folder on-files)
  (check-lister 'projects:list-with-git folder on-files)
  (git-listing (with-slash folder) (merge-submodules?) on-files))

(define (list-with-find folder on-files)
  (check-lister 'projects:list-with-find folder on-files)
  (find-listing (with-slash folder) (ignores) on-files))

(add-hook! finders try-vc 10)
