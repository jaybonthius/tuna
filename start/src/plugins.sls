#!tuna
(import (plugins files) (plugins installs) (plugins library-lines) (plugins conditions))

(module %manager (start-plugins! read-configuration-lines! read-configuration-line! configuration-line read-repl-line! raise-line-failure
                  plugin-line? line-id index-module? install-plugin! update-plugin! remove-plugin!
                  remove-unused-plugins! installed-plugins plugin-commit module-plugin-source
                  configuration-file module-file-of install-own-libraries! own-plugin-ids
                  reached-left-out unavailable-library-of build-failure-of test-library-names failure-text)
  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (eqv? (get-thread-id) main-thread)
      (assertion-violation who "only the main thread installs and removes plugins")))

  (define (report-safely c) (report c))

  (define (report-warning who text)
    (report (condition (make-warning) (make-who-condition who) (make-message-condition text))))

  (define cache-root #f)

  ;; A module (x ...) is only ever plugin x's, and (x-test ...) only its
  ;; tests', so of Tuna's own plugins only that root is searched for it.
  (define (library-source name)
    (let-values ([(source object found?)
                  (default-library-search-handler 'import name (search-roots (car name)) (library-extensions))])
      source))

  (define other-roots #f)
  (define own-roots (make-eq-hashtable))

  (define (search-roots part)
    (if other-roots
        (let ([own (hashtable-ref own-roots part #f)])
          (if own (append other-roots (list own)) other-roots))
        (library-directories)))

  (define (found-library-source name) (library-source name))

  (define (loaded-modules-under folder)
    (filter (lambda (name) (under? folder (library-source name))) (loaded-modules)))

  (define (loaded-libraries-under folder)
    (filter (lambda (name) (under? folder (library-source name))) (library-list)))

  (define (module-file-of name) (library-source name))

  ;; The kernel's own entries, which the plugin manager keeps ahead of its
  ;; roots; kept by Chez's property list, since they are the process's and
  ;; outlive this module's reload.
  (define (kernel-library-directories)
    (or (getprop 'plugins 'kernel-library-directories #f)
        (let ([directories (library-directories)])
          (putprop 'plugins 'kernel-library-directories directories)
          directories)))

  ;; Read as data, so what a module imports is known before it loads.
  (define (module-imports name)
    (let ([source (library-source name)])
      (if (and source (file-exists? source))
          (guard (c [#t '()])
            (call-with-input-file source
              (lambda (p)
                (get-line p)
                (let loop ([imports '()])
                  (let ([form (read p)])
                    (if (and (pair? form) (eq? (car form) 'import))
                        (loop (append imports (filter values (map import-spec-library (cdr form)))))
                        imports))))))
          '())))

  (define (configuration-file) configuration-file*)

  (define tuna-program #f)
  (define home #f)
  (define configuration-file* #f)
  (define lib-root #f)
  (define own-plugins-root #f)
  (define plugins-root #f)
  (define own-libraries-root #f)
  (define libraries-root #f)

  (define (start-plugins! program home-folder configuration lib own-plugins plugins own-libraries libraries cache install?)
    (set! installing-own? install?)
    (set! cache-root cache)
    (set! tuna-program program)
    (set! home home-folder)
    (set! configuration-file* configuration)
    (set! lib-root lib)
    (set! own-plugins-root own-plugins)
    (set! plugins-root plugins)
    (set! own-libraries-root own-libraries)
    (set! libraries-root libraries))

  (define (cache-folder part id) (format "~a/~a/~a" cache-root part id))

  (define (own-plugin-folder id) (format "~a/~a" own-plugins-root id))
  (define (own-plugin-root id) (string-append (own-plugin-folder id) "/src"))

  (define (own-plugin-ids)
    (if (file-directory? own-plugins-root)
        (filter (lambda (id) (and (install-id? id) (file-directory? (own-plugin-root id))))
                (map string->symbol (sort string<? (directory-list own-plugins-root))))
        '()))

  (define (clause? c)
    (and (list? c) (fx= (length c) 2) (memq (car c) '(git commit branch dir local)) (string? (cadr c))))

  (define (config-clause? c)
    (and (pair? c) (eq? (car c) 'config) (list? c)))

  (define (plugin-line? x)
    (and (list? x) (fx>= (length x) 2) (eq? (car x) 'use-plugin) (install-id? (cadr x))
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

  (define (module-file root name)
    (let ([base (format "~a/~a~{/~a~}" root (car name) (cdr name))])
      (find file-exists? (map (lambda (extension) (string-append base extension)) (source-extensions)))))

  (define (lib-module? name) (and (module-file lib-root name) #t))

  (define (under? folder path)
    (and path (string-prefix? (string-append folder "/") path)))

  ;; Lines are installed before the code that imports their libraries
  ;; compiles, so they are read as data first.
  (define configuration-lines '())
  (define configuration-library-lines '())
  (define repl-lines '())
  (define repl-library-lines '())

  (define (configuration-line id)
    (find (lambda (line) (eq? (line-id line) id)) configuration-lines))

  (define (repl-line id)
    (find (lambda (line) (eq? (line-id line) id)) repl-lines))

  (define (configuration-text)
    (if (file-exists? configuration-file*) (read-text-file configuration-file*) ""))

  ;; A read error ends the configuration where it stands, as when it runs.
  (define (configuration-forms)
    (let ([p (open-string-input-port (configuration-text))])
      (let loop ([forms '()])
        (let ([form (guard (c [(lexical-violation? c) (eof-object)]) (read p))])
          (if (eof-object? form)
              (reverse forms)
              (loop (cons form forms)))))))

  (define (first-lines forms line? id who)
    (let loop ([forms forms] [lines '()])
      (cond
        [(null? forms) (reverse lines)]
        [(not (line? (car forms))) (loop (cdr forms) lines)]
        [(find (lambda (line) (eq? (cadr line) (id (car forms)))) lines)
         (report-safely
           (condition (make-error) (make-who-condition who)
             (make-message-condition (format "a second line for ~a" (id (car forms))))))
         (loop (cdr forms) lines)]
        [else (loop (cdr forms) (cons (car forms) lines))])))

  (define (read-configuration-lines!)
    (let ([forms (configuration-forms)])
      (set! configuration-lines (first-lines forms plugin-line? line-id 'use-plugin))
      (set! configuration-library-lines (first-lines forms library-line? library-line-id 'library)))
    (resolve! configuration-lines))

  (define (replaced-line line id lines)
    (cons line (remp (lambda (known) (eq? (cadr known) id)) lines)))

  (define (read-repl-line! form)
    (cond
      [(plugin-line? form)
       (set! repl-lines (replaced-line form (line-id form) repl-lines))
       (resolve! (list form))]
      [(library-line? form)
       (set! repl-library-lines (replaced-line form (library-line-id form) repl-library-lines))
       (resolve! '())]))

  (define (set-configuration-line! id line)
    (set! configuration-lines
      (cond
        [(not line) (remp (lambda (known) (eq? (line-id known) id)) configuration-lines)]
        [(configuration-line id)
         (map (lambda (known) (if (eq? (line-id known) id) line known)) configuration-lines)]
        [else (append configuration-lines (list line))])))

  (define (read-configuration-line! form)
    (cond
      [(plugin-line? form)
       (set-configuration-line! (line-id form) form)
       (resolve! (list form))]
      [(library-line? form)
       (set! repl-library-lines (remp (lambda (known) (eq? (library-line-id known) (library-line-id form))) repl-library-lines))
       (set! configuration-library-lines
         (if (find (lambda (known) (eq? (library-line-id known) (library-line-id form))) configuration-library-lines)
             (map (lambda (known) (if (eq? (library-line-id known) (library-line-id form)) form known))
                  configuration-library-lines)
             (append configuration-library-lines (list form))))
       (resolve! '())]))

  ;; A line that could not be resolved raises where it is evaluated, so
  ;; the report names the line and its place.
  (define line-failures (make-hashtable equal-hash equal?))

  ;; Chez's library form names its library with a list, so a symbol there
  ;; is always a library line.
  (define (raise-line-failure form)
    (let ([failure (cond
                     [(plugin-line? form) (hashtable-ref line-failures (cons 'plugin (line-id form)) #f)]
                     [(library-line? form) (hashtable-ref line-failures (cons 'library (library-line-id form)) #f)]
                     [(and (pair? form) (eq? (car form) 'library) (pair? (cdr form)) (symbol? (cadr form)))
                      (condition (make-syntax-violation form #f) (make-who-condition 'library)
                        (make-message-condition
                          "expected an id and clauses (git url) with (commit hex), (local folder), (library-directories root ...) or (build program argument ...)"))]
                     [else #f])])
      (when failure (raise failure))))

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

  (define install-sources (make-eq-hashtable))

  (define (installed-source id)
    (let ([known (hashtable-ref install-sources id 'unread)])
      (if (eq? known 'unread)
          (let ([found (read-install-source id)])
            (hashtable-set! install-sources id found)
            found)
          known)))

  (define (install-folder id found)
    (or (install-source-local found)
        (let ([dir (install-source-dir found)])
          (if dir (string-append (plugin-folder id) "/" dir) (plugin-folder id)))))

  (define (install-root id found) (string-append (install-folder id found) "/src"))

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
                (if (and (install-id? id) (not (memq id ids))) (cons id ids) ids)))
            '()
            (directory-list plugins-root)))
        '()))

  (define (installed-plugins)
    (let* ([ids (installed-ids)]
           [named (filter (lambda (id) (memq id ids)) (map line-id configuration-lines))])
      (append named
        (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
              (remp (lambda (id) (memq id named)) ids)))))

  (define (plugin-commit id)
    (unless (install-id? id) (assertion-violation 'plugin-commit "not a plugin id" id))
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

  ;; An index's main module is data, never compiled, and a local index may
  ;; be edited, so its lines are read from its file when it changes.
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

  (define (module-plugin-source name)
    (let ([source (found-library-source name)])
      (cond
        [(lib-module? name) 'user]
        [(find (lambda (id)
                 (let ([root (install-root id (installed-source id))])
                   (if source (under? root source) (module-file root name))))
               (installed-ids))
         => (lambda (id)
              (let ([found (installed-source id)])
                (or (install-source-git found) (install-source-local found) (plugin-folder id))))]
        [else 'tuna])))

  (define (own-plugin-file? id path) (under? (own-plugin-root id) path))

  (define (plugin-modules id)
    (let ([found (installed-source id)])
      (filter (lambda (name)
                (and (not (lib-module? name))
                     (let ([source (found-library-source name)])
                       (if found
                           (under? (install-root id found) source)
                           (own-plugin-file? id source)))))
              (loaded-modules))))

  (define (build-log id) (format "~a/builds/~a.log" cache-root id))

  ;; One install or update may build twice, when an update goes back, so
  ;; the log is started once for it and each build adds to it.
  (define (start-build-log! log)
    (delete-file log #f))

  (define (build-plugin! who id url folder root)
    (build! who id url folder root #f tuna-program (build-log id)))

  (define (temporary-folder id) (format "~a/.~a.new" plugins-root id))

  (define (git-clauses url dir branch)
    `((git ,url) ,@(if dir `((dir ,dir)) '()) ,@(if branch `((branch ,branch)) '())))

  (define (line-git-clauses line)
    (git-clauses (git-address (line-clause line 'git)) (line-clause line 'dir) (line-clause line 'branch)))

  (define (source-clauses found)
    (git-clauses (install-source-git found) (install-source-dir found) (install-source-branch found)))

  ;; A build may write the plugin's main module, so installs and updates
  ;; check for it after the build.
  (define (check-main-module who id root)
    (unless (module-file root (list id))
      (errorf who "plugin ~a holds no module (~a)" id id)))

  ;; Chez's lookup takes the first root that holds a name, so a second
  ;; provider would be passed over without a word. Names Tuna keeps for
  ;; itself never reach an installed root. An installed plugin replaces
  ;; Tuna's own plugin of its id.
  (define (check-library-names! who owner roots)
    (let ([files (apply append (map library-files roots))])
      (for-each
        (lambda (file)
          (when (reserved-library-name? (car file))
            (errorf who "~a holds the library ~s, a name Tuna keeps for itself" (describe-requester owner) (car file))))
        files)
      (for-each
        (lambda (provider)
          (unless (equal? (car provider) owner)
            (for-each
              (lambda (theirs)
                (when (and (assoc (car theirs) files)
                           (not (and (eq? (car owner) 'plugin) (equal? (car provider) (cons 'tuna (cdr owner))))))
                  (errorf who "~a and ~a both hold the library ~s"
                    (describe-requester owner) (describe-requester (car provider)) (car theirs))))
              (library-files (cdr provider)))))
        (providers))
      files))

  (define (providers)
    (append
      (map (lambda (id) (cons (cons 'plugin id) (install-root id (installed-source id)))) (installed-ids))
      (apply append
        (map (lambda (id)
               (map (lambda (root) (cons (cons 'library id) (car root)))
                    (location-roots (hashtable-ref library-locations id #f))))
             (located-libraries)))
      (map (lambda (id) (cons (cons 'tuna id) (own-plugin-root id))) (own-plugin-ids))))

  ;; The build runs in the plugin's own folder, since what it makes may
  ;; record its path, so the old folder is moved aside, not deleted, and
  ;; kept until the build succeeds.
  (define (replace-folder! who line temporary run-build)
    (let* ([id (line-id line)] [dir (line-clause line 'dir)]
           [folder (plugin-folder id)] [root (if dir (string-append folder "/" dir) folder)]
           [old (format "~a/.~a.old" plugins-root id)])
      (delete-tree old)
      (when (file-exists? folder #f) (rename-file folder old))
      (rename-file temporary folder)
      (start-build-log! (build-log id))
      (guard (c [#t (delete-tree folder)
                    (when (file-exists? old #f) (rename-file old folder))
                    (raise c)])
        (run-build
          (lambda ()
            (build-plugin! who id (git-address (line-clause line 'git)) folder root)))
        (check-main-module who id (string-append root "/src"))
        (check-library-names! who (cons 'plugin id) (list (string-append root "/src"))))
      (delete-tree old)))

  (define (finish-install! who line temporary run-build)
    (let ([id (line-id line)])
      (replace-folder! who line temporary run-build)
      (write-install-source! id (line-git-clauses line))
      (hashtable-delete! index-lines-read id)))

  (define (install-local! who id folder)
    (check-main-module who id (string-append folder "/src"))
    (check-library-names! who (cons 'plugin id) (list (string-append folder "/src")))
    (delete-tree (plugin-folder id))
    (write-install-source! id `((local ,folder)))
    (hashtable-delete! index-lines-read id))

  (define (install-paused! who line)
    (let ([id (line-id line)] [local (line-clause line 'local)])
      (check-not-fetching who (plugin-folder id) "plugin")
      (if local
          (begin (install-local! who id (local-folder local)) #f)
          (let ([url (git-address (line-clause line 'git))] [temporary (temporary-folder id)])
            (make-folders! plugins-root)
            (call-paused who (plugin-folder id) "plugin"
              (lambda () (clone! who url (line-clause line 'commit) (line-clause line 'branch) temporary)))
            (finish-install! who line temporary (lambda (build) (call-paused who (plugin-folder id) "plugin" build)))
            (checked-out-commit (plugin-folder id))))))

  (define (check-not-start-plugin who id)
    (when (memq id '(start plugins))
      (errorf who "~a loads before any line is read, so only tuna --start=FOLDER replaces it" id)))

  ;; A plugin whose modules are loaded keeps its files until it is updated
  ;; or Tuna starts again, so that resolving never changes code that runs.
  ;; plugins/ is Tuna's to manage, but a copy may have been put there by
  ;; hand, so a replacement or a removal is reported.
  (define (resolve-plugin-line! line)
    (check-not-start-plugin 'use-plugin (line-id line))
    (let* ([id (line-id line)] [found (installed-source id)] [resolved (resolve-line line)])
      (cond
        [resolved
         (cond
           [(not found) (install-paused! 'use-plugin resolved)]
           [(or (installed-from? resolved id found) (pair? (plugin-modules id))) (void)]
           [else
            (let ([replaced? (file-exists? (plugin-folder id) #f)])
              (install-paused! 'use-plugin resolved)
              (when replaced?
                (report-warning 'use-plugin
                  (format "replaced ~a, installed from another source or commit than its line's" (plugin-folder id)))))])]
        [(module-file (own-plugin-root id) (list id))
         (when (and found (null? (plugin-modules id)))
           (when (file-exists? (plugin-folder id) #f)
             (report-warning 'use-plugin
               (format "removed ~a: its line finds the plugin among Tuna's own plugins" (plugin-folder id))))
           (uninstall! id))]
        [found (void)]
        [else
         (errorf 'use-plugin "the line for ~a has no source: give it a git or local clause, or use an index that names it"
           id)])))

  (define-record-type location
    (nongenerative)
    (sealed #t)
    (fields folder line roots))

  (define library-locations (make-eq-hashtable))

  (define (located-libraries)
    (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
          (vector->list (hashtable-keys library-locations))))

  ;; Tuna's own plugins' libraries are installed beside the program, so
  ;; each install keeps the commits its plugins name; the rest are the
  ;; user's.
  (define (library-folder root id) (format "~a/~a" root id))
  (define (library-source-file folder) (string-append folder ".installed"))
  (define (compare-folder id) (format "~a/.~a.compare" libraries-root id))
  (define (library-build-log id) (format "~a/builds/libraries/~a.log" cache-root id))

  (define (make-library-location id folder line)
    (make-location folder line
      (let ([roots (library-line-roots line)])
        (if roots
            (map (lambda (root) (cons (string-append folder "/" (car root)) (string-append folder "/" (cdr root))))
                 roots)
            (list (cons folder folder))))))

  (define (location-pairs location id)
    (if (library-line-roots (location-line location))
        (location-roots location)
        (list (cons (location-folder location) (cache-folder "libraries" id)))))

  (define (installed-library-line folder)
    (let ([file (library-source-file folder)])
      (and (file-exists? file) (file-directory? folder)
           (let ([line (guard (c [#t #f]) (call-with-input-file file read))])
             (and (library-line? line) line)))))

  (define (installed-library-from? folder line)
    (let ([installed (installed-library-line folder)] [head (checked-out-commit folder)])
      (and installed head
           (library-lines-equal? installed line)
           (commits-equal? head (library-line-clause line 'commit)))))

  (define (library-line-with-git line)
    `(library ,(library-line-id line)
       ,@(map (lambda (c) (if (eq? (car c) 'git) `(git ,(git-address (cadr c))) c)) (cddr line))))

  ;; A library holds plain Chez libraries, which load once per process:
  ;; Tuna modules are a plugin's, so that they can reload.
  (define (check-library-folder! who id line folder)
    (let ([files (check-library-names! who (cons 'library id)
                   (map car (location-roots (make-library-location id folder line))))])
      (let ([module (find (lambda (file) (tuna-file? (cdr file))) files)])
        (when module
          (errorf who "library ~a holds the Tuna module ~s; install it with a use-plugin line" id (car module))))))

  (define (install-library! who root id line)
    (let* ([url (library-line-clause line 'git)]
           [folder (library-folder root id)]
           [temporary (format "~a/.~a.new" root id)]
           [old (format "~a/.~a.old" root id)]
           [log (library-build-log id)])
      (check-not-fetching who folder "library")
      (make-folders! root)
      (let ([commit (library-line-clause line 'commit)]
            [compare (and (string=? root libraries-root) (not (fetching? (compare-folder id))) (compare-folder id))])
        (call-paused who folder "library"
          (lambda ()
            (if (and compare (file-directory? compare) (commit-present? compare commit))
                (begin
                  (delete-tree temporary)
                  (rename-file compare temporary)
                  (guard (c [#t (delete-tree temporary) (raise c)])
                    (check-out! who url temporary commit #f)))
                (clone! who url commit #f temporary)))))
      (delete-tree old)
      (when (file-exists? folder #f) (rename-file folder old))
      (rename-file temporary folder)
      (delete-file (library-source-file folder) #f)
      (start-build-log! log)
      (guard (c [#t (delete-tree folder)
                    (when (file-exists? old #f) (rename-file old folder))
                    (raise c)])
        (call-paused who folder "library"
          (lambda ()
            (build! who (format "library ~a" id) url folder folder (library-line-build line) tuna-program log)))
        (check-library-folder! who id line folder))
      (delete-tree old)
      (make-folders! root)
      (write-file-atomically! (library-source-file folder) (format "~s\n" line))))

  ;; Commits never change, so an answer holds for the process; asking git
  ;; again would cost every resolution, start-up included.
  (define descendants (make-hashtable equal-hash equal?))

  (define (descendant who id)
    (lambda (url commits)
      (and url
           (let* ([url (git-address url)] [key (cons url (sort string<? commits))])
             (if (hashtable-contains? descendants key)
                 (hashtable-ref descendants key #f)
                 (let ([found (find-descendant who id url commits)])
                   (hashtable-set! descendants key found)
                   found))))))

  ;; The installed clone holds every commit an installed choice descends
  ;; from, so comparing again at the next start needs no network. The
  ;; install's clone is only read, since other Tunas run from it.
  (define (holds-commits? folder commits)
    (and (file-directory? folder) (for-all (lambda (commit) (commit-present? folder commit)) commits)))

  (define (descendant-in folder commits)
    (find (lambda (commit)
            (for-all (lambda (other) (or (commits-equal? other commit) (ancestor? folder other commit)))
                     commits))
          commits))

  (define (find-descendant who id url commits)
    (define (installed-from root)
      (let* ([folder (library-folder root id)] [installed (installed-library-line folder)])
        (and installed (equal? (library-line-clause installed 'git) url) folder)))
    (let ([own (installed-from own-libraries-root)])
      (if (and own (call-paused who own "library" (lambda () (holds-commits? own commits))))
          (call-paused who own "library" (lambda () (descendant-in own commits)))
          (let ([folder (or (installed-from libraries-root) (compare-folder id))])
            (call-paused who folder "library"
              (lambda ()
                (unless (holds-commits? folder commits)
                  (make-folders! libraries-root)
                  (if (file-directory? (string-append folder "/.git"))
                      (git who url "-C" folder "fetch" "--quiet" "origin")
                      (begin
                        (delete-tree folder)
                        (git who url "clone" "--quiet" "--no-checkout" url folder)))
                  (for-each (lambda (commit)
                              (unless (commit-present? folder commit)
                                (errorf who "commit ~a not found in ~a" commit url)))
                            commits))
                (descendant-in folder commits)))))))

  ;; Only tuna --install installs a library for Tuna's own plugins or
  ;; their tests: several Tunas run from one install at once, and each
  ;; would write the same folder.
  (define installing-own? #f)

  (define (own-requester? requester)
    (or (and (pair? requester) (memq (car requester) '(tuna test-files)) #t)
        (and (pair? requester) (eq? (car requester) 'library)
             (let ([location (hashtable-ref library-locations (cdr requester) #f)])
               (and location (under? own-libraries-root (location-folder location)))))))

  (define (own-line? line requests)
    (exists (lambda (r) (and (own-requester? (cdr r)) (library-lines-equal? (car r) line))) requests))

  (define (place-library! id line requests)
    (let ([own-folder (library-folder own-libraries-root id)])
      (cond
        [(and (own-line? line requests) (installed-library-from? own-folder line))
         (make-library-location id own-folder line)]
        [(and (own-line? line requests) installing-own?)
         (guard (c [(not (cancelled? c)) (hashtable-set! unavailable-libraries id c) #f])
           (install-library! 'library own-libraries-root id line)
           (make-library-location id own-folder line))]
        [(library-line-clause line 'local)
         => (lambda (folder)
              (let ([folder (local-folder folder)])
                (check-library-folder! 'library id line folder)
                (make-library-location id folder line)))]
        [(for-all (lambda (r) (own-requester? (cdr r))) requests)
         (hashtable-set! unavailable-libraries id
           (condition (make-error) (make-who-condition 'library)
             (make-message-condition (format "Tuna's install does not hold library ~a" id))))
         #f]
        [else
         (let ([line (library-line-with-git line)] [folder (library-folder libraries-root id)])
           (unless (installed-library-from? folder line)
             (install-library! 'library libraries-root id line))
           (make-library-location id folder line))])))

  ;; Every resolution meets the same failures again, so each is reported
  ;; once per process.
  (define reported-texts (make-hashtable string-hash string=?))

  (define (report-warning-once who text)
    (unless (hashtable-contains? reported-texts text)
      (hashtable-set! reported-texts text #t)
      (report-warning who text)))

  (define (report-once c)
    (let ([text (condition-text c)])
      (unless (hashtable-contains? reported-texts text)
        (hashtable-set! reported-texts text #t)
        (report-safely c))))

  (define (loaded-location? location)
    (pair? (loaded-libraries-under (location-folder location))))

  ;; Chez loads a library once per process, so a library whose libraries
  ;; are loaded keeps its files until the next start.
  (define (locate-library! id requests)
    (let-values ([(line overridden) (choose-library-line 'library id requests (descendant 'library id))])
      (for-each
        (lambda (requester)
          (report-warning-once 'library
            (format "~a line for library ~a replaces that of ~a"
              (if (find (lambda (r) (eq? (cdr r) 'repl)) requests) "the REPL's" "the configuration's")
              id (describe-requester requester))))
        overridden)
      (let ([current (hashtable-ref library-locations id #f)])
        (cond
          [(and current (library-lines-equal? (location-line current) line)
                (or (not (library-line-clause line 'git))
                    (installed-library-from? (location-folder current) (library-line-with-git line))))
           (void)]
          [(and current (loaded-location? current))
           (report-warning-once 'library
             (format "library ~a is loaded, so its new line takes effect when Tuna starts again" id))]
          [(place-library! id line requests) => (lambda (location) (hashtable-set! library-locations id location))]
          [else (hashtable-delete! library-locations id)]))))

  (define (failure-text c)
    (if (condition? c)
        (condition-text (apply condition (remp who-condition? (simple-conditions c))))
        (condition-text c)))

  (define (wrapped-failure who text c)
    (condition (make-error) (make-who-condition who)
      (make-message-condition (format "~a: ~a" text (failure-text c)))))

  (define (fail-library! id requests c)
    (for-each
      (lambda (requester)
        (cond
          [(memq requester '(configuration repl))
           (hashtable-set! line-failures (cons 'library id) c)]
          [(and (pair? requester) (eq? (car requester) 'plugin))
           (unless (hashtable-contains? line-failures requester)
             (hashtable-set! line-failures requester
               (wrapped-failure 'use-plugin (format "plugin ~a needs library ~a" (cdr requester) id) c)))]
          [else (report-once c)]))
      (let loop ([requesters (map cdr requests)] [unique '()])
        (cond
          [(null? requesters) (reverse unique)]
          [(member (car requesters) unique) (loop (cdr requesters) unique)]
          [else (loop (cdr requesters) (cons (car requesters) unique))]))))

  (define (requests-of requester folder)
    (guard (c [(not (cancelled? c))
               (if (and (pair? requester) (eq? (car requester) 'plugin))
                   (hashtable-set! line-failures requester c)
                   (report-once c))
               '()])
      (map (lambda (line) (cons line requester))
           (read-library-requests (if (and (pair? requester) (eq? (car requester) 'plugin)) 'use-plugin 'library)
             (string-append folder "/tuna.deps")))))

  ;; A plugin being installed or updated has no line yet, or one for its
  ;; previous commit, so it asks for the libraries of the commit it is
  ;; getting, and remove-unused-plugins! leaves it alone.
  (define installing (make-eq-hashtable))

  (define (call-installing id thunk)
    (define (done!)
      (let ([n (fx- (hashtable-ref installing id 1) 1)])
        (if (fx= n 0) (hashtable-delete! installing id) (hashtable-set! installing id n))))
    (hashtable-update! installing id fx1+ 0)
    (let ([result (guard (c [#t (done!) (raise c)]) (thunk))])
      (done!)
      result))

  (define (lined-plugins)
    (filter installed-source
      (fold-right (lambda (id ids) (if (memq id ids) ids (cons id ids)))
                  '()
                  (append (map line-id (append configuration-lines repl-lines))
                          (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                                (vector->list (hashtable-keys installing)))))))

  (define (base-requests)
    (append
      (map (lambda (line) (cons line 'configuration)) configuration-library-lines)
      (map (lambda (line) (cons line 'repl)) repl-library-lines)
      (apply append
        (map (lambda (id)
               (append (requests-of (cons 'tuna id) (own-plugin-folder id))
                       (requests-of (cons 'test-files id) (string-append (own-plugin-folder id) "/tests"))))
             (own-plugin-ids)))
      (requests-of '(test-files . start) (string-append (path-parent tuna-program) "/start"))
      (apply append
        (map (lambda (id) (requests-of (cons 'plugin id) (install-folder id (installed-source id))))
             (lined-plugins)))))

  (define (request-ids requests)
    (fold-left (lambda (ids r) (if (memq (library-line-id (car r)) ids) ids (append ids (list (library-line-id (car r))))))
               '() requests))

  ;; A library may name libraries of its own, so the libraries chosen give
  ;; requests in turn, until the choices settle.
  (define (resolve-libraries!)
    (let ([base (base-requests)])
      (hashtable-clear! unavailable-libraries)
      (hashtable-clear! library-requesters)
      (let loop ([extra '()] [earlier '()])
        (let ([requests (append base extra)])
          (for-each
            (lambda (id)
              (hashtable-delete! line-failures (cons 'library id))
              (hashtable-delete! unavailable-libraries id)
              (let ([mine (filter (lambda (r) (eq? (library-line-id (car r)) id)) requests)])
                (hashtable-set! library-requesters id (map cdr mine))
                (guard (c [(not (cancelled? c)) (fail-library! id mine c)])
                  (locate-library! id mine))))
            (request-ids requests))
          (for-each
            (lambda (id)
              (unless (or (memq id (request-ids requests))
                          (loaded-location? (hashtable-ref library-locations id #f)))
                (hashtable-delete! library-locations id)))
            (located-libraries))
          (let ([next (apply append
                        (map (lambda (id)
                               (requests-of (cons 'library id)
                                 (location-folder (hashtable-ref library-locations id #f))))
                             (located-libraries)))])
            (cond
              [(equal? next extra) (void)]
              [(member next earlier)
               (report-once
                 (condition (make-error) (make-who-condition 'library)
                   (make-message-condition "the tuna.deps files of the libraries chosen ask for one another in a cycle that never settles")))]
              [else (loop next (cons extra earlier))]))))))

  (define unavailable-libraries (make-eq-hashtable))
  (define library-requesters (make-eq-hashtable))

  (define (needing-plugins)
    (let ([needing (make-eq-hashtable)])
      (vector-for-each
        (lambda (id)
          (let walk ([requesters (hashtable-ref library-requesters id '())] [seen (list id)])
            (for-each
              (lambda (r)
                (cond
                  [(not (pair? r)) (void)]
                  [(eq? (car r) 'tuna)
                   (unless (hashtable-contains? needing (cdr r)) (hashtable-set! needing (cdr r) id))]
                  [(and (eq? (car r) 'library) (not (memq (cdr r) seen)))
                   (walk (hashtable-ref library-requesters (cdr r) '()) (cons (cdr r) seen))]))
              requesters)))
        (hashtable-keys unavailable-libraries))
      needing))

  ;; A failed build is kept beside the plugin's folder, so every start from
  ;; the install leaves the plugin out, as tuna --install did.
  (define (build-failure-file id) (string-append (own-plugin-folder id) ".failed"))

  (define (failed-builds)
    (let ([failed (make-eq-hashtable)])
      (when (file-directory? own-plugins-root)
        (for-each
          (lambda (entry)
            (when (string=? (path-extension entry) "failed")
              (hashtable-set! failed (string->symbol (path-root entry))
                (read-text-file (string-append own-plugins-root "/" entry)))))
          (directory-list own-plugins-root)))
      failed))

  (define (build-own-plugins!)
    (for-each
      (lambda (id)
        (let ([folder (own-plugin-folder id)])
          (delete-file (build-failure-file id) #f)
          (when (file-exists? (string-append folder "/build.ss"))
            (start-build-log! (build-log id))
            (guard (c [(not (cancelled? c))
                       (write-file-atomically! (build-failure-file id) (failure-text c))])
              (call-paused 'install folder "plugin"
                (lambda () (run-build! 'install (format "plugin ~a" id) folder folder #f tuna-program (build-log id))))))))
      (own-plugin-ids)))

  ;; Imports are read from source, so a form that would load a plugin left
  ;; out of the install fails before anything loads, naming the plugin and
  ;; why. A module counts only where the lookup finds it in its own
  ;; plugin's root, so a stand-in in lib/ or an installed plugin loads.
  (define needing #f)
  (define failed #f)
  (define reached #f)

  (define (forget-left-out!)
    (set! needing #f)
    (set! failed #f)
    (set! reached #f))

  (define (find-left-out!)
    (unless reached
      (set! needing (needing-plugins))
      (set! failed (failed-builds))
      (set! reached (make-hashtable equal-hash equal?))))

  (define (left-out-id? id)
    (or (hashtable-contains? needing id) (hashtable-contains? failed id)))

  (define (reached-left-out name)
    (find-left-out!)
    (and (fx> (fx+ (hashtable-size needing) (hashtable-size failed)) 0)
         (let reach ([name name])
           (if (hashtable-contains? reached name)
               (hashtable-ref reached name #f)
               (begin
                 (hashtable-set! reached name #f)
                 (let ([found (if (and (left-out-id? (car name)) (own-plugin-file? (car name) (library-source name)))
                                  (car name)
                                  (exists reach (module-imports name)))])
                   (hashtable-set! reached name found)
                   found))))))

  (define (unavailable-library-of plugin) (find-left-out!) (hashtable-ref needing plugin #f))
  (define (build-failure-of plugin) (find-left-out!) (hashtable-ref failed plugin #f))

  (define (install-own-libraries!)
    (unless installing-own?
      (assertion-violation 'plugins:install-all! "only a Tuna started by plugins:start-install! installs"))
    (build-own-plugins!)
    (read-configuration-lines!)
    (sort (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b))))
          (let-values ([(ids failures) (hashtable-entries unavailable-libraries)])
            (map cons (vector->list ids) (vector->list failures)))))

  ;; No plugin's import reaches a library its tests name, so install loads
  ;; each of its libraries, compiling them before tests run.
  (define (test-library-names)
    (apply append
      (map (lambda (id)
             (if (exists (lambda (r) (and (pair? r) (eq? (car r) 'test-files)))
                         (hashtable-ref library-requesters id '()))
                 (apply append
                   (map (lambda (root) (map car (library-files (car root))))
                        (location-roots (hashtable-ref library-locations id #f))))
                 '()))
           (located-libraries))))

  (define (library-roots)
    (append
      (map (lambda (id) (cons (install-root id (installed-source id)) (cache-folder "plugins" id)))
           (installed-plugins))
      (apply append
        (map (lambda (id) (location-pairs (hashtable-ref library-locations id #f) id)) (located-libraries)))))

  ;; The user's own module wins over an installed plugin's or library's of
  ;; the same name, as the configuration's line wins over a plugin's; one
  ;; that replaces Tuna's own is the usual stand-in and goes unreported.
  (define (report-lib-overrides! roots)
    (for-each
      (lambda (file)
        (let-values ([(source object found?)
                      (default-library-search-handler 'import (car file) roots (library-extensions))])
          (when source
            (report-warning-once 'import (format "~a in lib/ replaces ~a" (car file) source)))))
      (library-files lib-root)))

  ;; Installs wait their turn, since each reads and changes what the
  ;; others do. A task leaves its dynamic extent each time it pauses, so
  ;; the turn ends on return or raise, not in a dynamic-wind.
  (define resolving? #f)
  (define waiting '())

  (define (call-resolving who thunk)
    (define (end-turn!)
      (set! resolving? #f)
      (let ([resumes waiting])
        (set! waiting '())
        (for-each (lambda (resume) (resume void)) resumes)))
    (let wait ()
      (when resolving?
        (if (current-task)
            (suspend (lambda (resume) (set! waiting (cons resume waiting))))
            (assertion-violation who "plugins and libraries are being installed"))
        (wait)))
    (set! resolving? #t)
    (let ([results (guard (c [#t (end-turn!) (raise c)]) (call-with-values thunk list))])
      (end-turn!)
      (apply values results)))

  (define (resolve! lines)
    (for-each
      (lambda (line)
        (let ([key (cons 'plugin (line-id line))])
          (hashtable-delete! line-failures key)
          (guard (c [(not (cancelled? c)) (hashtable-set! line-failures key c)])
            (resolve-plugin-line! line))))
      lines)
    (refresh-roots!))

  (define (resolve-roots!)
    (resolve-libraries!)
    (forget-left-out!)
    (let ([roots (library-roots)]
          [own (apply append
                 (map (lambda (id)
                        (let ([objects (format "~a/library/~a" cache-root id)]
                              [tests (string-append (own-plugin-folder id) "/tests/lib")])
                          (cons (cons id (cons (own-plugin-root id) objects))
                                (if (file-directory? tests)
                                    (list (cons (string->symbol (format "~a-test" id)) (cons tests objects)))
                                    '()))))
                      (own-plugin-ids)))])
      (set! other-roots
        (append (kernel-library-directories) (list (cons lib-root (string-append cache-root "/lib"))) roots))
      (hashtable-clear! own-roots)
      (for-each (lambda (entry) (hashtable-set! own-roots (car entry) (cdr entry))) own)
      (library-directories (append other-roots (map cdr own)))
      (report-lib-overrides! roots)))

  (define (refresh-roots!)
    (call-resolving 'use-plugin resolve-roots!))

  ;; Positions are in characters, so they index the text as read.
  (define-record-type span
    (nongenerative)
    (sealed #t)
    (fields start end datum annotation))

  (define (top-level-spans text)
    (let ([p (open-string-input-port text)]
          [sfd (make-source-file-descriptor configuration-file* (open-bytevector-input-port (string->utf8 text)))])
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

  (define (imports-tuna? form)
    (and (list? form) (pair? form) (eq? (car form) 'import)
         (exists (lambda (spec) (equal? (import-spec-library spec) '(tuna))) (cdr form))))

  ;; After the last line, else after an import of (tuna), else at the
  ;; start.
  (define (insertion-point who spans)
    (let ([lines (filter (lambda (s) (plugin-line? (span-datum s))) spans)])
      (cond
        [(pair? lines) (span-end (car (last-pair lines)))]
        [(find (lambda (s) (imports-tuna? (span-datum s))) spans) => span-end]
        [else 0])))

  (define (line-span id spans)
    (find (lambda (s) (and (plugin-line? (span-datum s)) (eq? (line-id (span-datum s)) id))) spans))

  (define (write-configuration! text)
    (make-folders! (path-parent configuration-file*))
    (write-file-atomically! configuration-file* text))

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

  ;; The plugin's libraries are part of its install, so a plugin whose
  ;; libraries fail is installed no more than one whose build fails.
  (define (install-plugin! line)
    (unless (plugin-line? line)
      (assertion-violation 'install-plugin! "not a use-plugin line" line))
    (check-main-thread 'install-plugin!)
    (let ([id (line-id line)])
      (check-not-start-plugin 'install-plugin! id)
      (when (configuration-line id)
        (assertion-violation 'install-plugin! "the configuration has a line for the plugin" id))
      (let ([source (or (resolve-line line)
                        (assertion-violation 'install-plugin! "no source for the plugin" id))])
        (insertion-point 'install-plugin! (top-level-spans (configuration-text)))
        (let* ([installed? (installed-source id)]
               [commit (install-paused! 'install-plugin! source)]
               [key (cons 'plugin id)])
          (hashtable-delete! line-failures key)
          (guard (c [#t (unless installed? (uninstall! id)) (raise c)])
            (call-installing id refresh-roots!))
          (let ([failure (hashtable-ref line-failures key #f)])
            (when failure
              (unless installed? (uninstall! id))
              (refresh-roots!)
              (raise failure)))
          (insert-configuration-line! 'install-plugin! (line-with-commit line commit))))))

  ;; One operation, so the plugin's modules end all new or all as before.
  (define (reload-plugin-modules! id)
    (let ([names (filter (lambda (name) (module-owner name)) (plugin-modules id))])
      (or (null? names)
          (guard (c [(cancelled? c) (raise c)] [#t (report c) #f])
            (reload-modules! names)
            #t))))

  (define update-plugin!
    (case-lambda
      [(id) (update-plugin! id #f)]
      [(id commit)
       (unless (install-id? id) (assertion-violation 'update-plugin! "not a plugin id" id))
       (unless (or (not commit) (string? commit)) (assertion-violation 'update-plugin! "not a commit" commit))
       (check-main-thread 'update-plugin!)
       (let ([found (or (installed-source id) (assertion-violation 'update-plugin! "not installed" id))])
         (when (install-source-local found)
           (assertion-violation 'update-plugin! "a local plugin is not fetched" id))
         (update-installed-plugin! id commit found))]))

  (define (update-installed-plugin! id commit found)
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
           [previous-line (configuration-line id)]
           [key (cons 'plugin id)])
      (define (go-back!)
        (when (install-source-git found)
          (write-install-source! id (source-clauses found)))
        (call-paused 'update-plugin! folder "plugin"
          (lambda ()
            (when (install-source-git found)
              (git 'update-plugin! url "-C" folder "remote" "set-url" "origin" (install-source-git found)))
            (when previous-commit
              (git 'update-plugin! url "-C" folder "checkout" "--quiet" "--detach" previous-commit))))
        ;; The update has failed already, so a failed build of the
        ;; previous commit is only reported.
        (when previous-commit
          (guard (c [#t (report-safely c)])
            (call-paused 'update-plugin! folder "plugin" (lambda () (build-plugin! 'update-plugin! id url folder root)))))
        (hashtable-delete! line-failures key)
        (refresh-roots!))
      (unless span
        (insertion-point 'update-plugin! (top-level-spans text)))
      (let ([new (call-paused 'update-plugin! folder "plugin"
                   (lambda ()
                     (fetch! 'update-plugin! url folder commit (and (not commit) (line-clause source 'branch)))))])
        (start-build-log! (build-log id))
        (guard (c [#t (go-back!) (raise c)])
          (call-paused 'update-plugin! folder "plugin" (lambda () (build-plugin! 'update-plugin! id url folder root)))
          (check-main-module 'update-plugin! id (string-append root "/src"))
          (check-library-names! 'update-plugin! key (list (string-append root "/src")))
          (hashtable-delete! line-failures key)
          (call-installing id refresh-roots!)
          (let ([failure (hashtable-ref line-failures key #f)])
            (when failure (raise failure))))
        (write-install-source! id (line-git-clauses source))
        (hashtable-delete! index-lines-read id)
        (write-configuration-commit! 'update-plugin! line new)
        (unless (reload-plugin-modules! id)
          (replace-line-text! id previous-line-text)
          (set-configuration-line! id previous-line)
          (go-back!)
          (reload-plugin-modules! id)
          (void)))))

  (define (uninstall! id)
    (delete-tree (plugin-folder id))
    (delete-tree (install-source-file id))
    (hashtable-delete! install-sources id)
    (hashtable-delete! index-lines-read id))

  (define (remove-plugin! id)
    (unless (install-id? id) (assertion-violation 'remove-plugin! "not a plugin id" id))
    (check-main-thread 'remove-plugin!)
    (unless (or (installed-source id) (configuration-line id))
      (assertion-violation 'remove-plugin! "not installed" id))
    ;; The line goes first: an unload of a module the configuration imports
    ;; reads the configuration again, which would load the plugin again.
    (comment-out-configuration-line! id)
    (for-each (lambda (name) (let ([o (module-owner name)]) (when o (unload-owner! o))))
              (reverse (plugin-modules id)))
    (uninstall! id)
    (refresh-roots!))

  (define (library-entry-id entry)
    (let ([name (if (string-prefix? "." entry) (substring entry 1 (string-length entry)) entry)])
      (string->symbol
        (if (member (path-extension name) '("installed" "new" "old" "compare")) (path-root name) name))))

  ;; A plugin is used while one of its modules is loaded; a library when
  ;; its line was chosen at the last resolution. Installs fill folders
  ;; while they hold the turn, and git that a cancelled install started
  ;; may still be filling one after.
  (define (remove-unused-plugins!)
    (check-main-thread 'remove-unused-plugins!)
    (call-resolving 'remove-unused-plugins!
      (lambda ()
        (for-each
          (lambda (id)
            (unless (or (configuration-line id)
                        (hashtable-contains? installing id)
                        (fetching? (plugin-folder id))
                        (pair? (loaded-modules-under (install-root id (installed-source id)))))
              (uninstall! id)))
          (installed-plugins))
        (when (file-directory? libraries-root)
          (for-each
            (lambda (entry)
              (let* ([id (library-entry-id entry)]
                     [location (hashtable-ref library-locations id #f)])
                (unless (or (fetching? (library-folder libraries-root id))
                            (fetching? (compare-folder id))
                            (and (not (string-prefix? "." entry))
                                 location
                                 (string=? (location-folder location) (library-folder libraries-root id))))
                  (delete-tree (string-append libraries-root "/" entry)))))
            (directory-list libraries-root)))
        (resolve-roots!)))))

(import (rename %manager (configuration-file %configuration-file)))

(define (configuration-file) (%configuration-file))

(define %self (current-owner))

(define (%start! program home configuration data cache install?)
  (let ([tuna (path-parent program)])
    (start-plugins! program home configuration (string-append (path-parent configuration) "/lib")
      (normal-path (string-append tuna "/plugins"))
      (string-append data "/plugins")
      (string-append tuna "/libraries")
      (string-append data "/libraries")
      cache
      install?)))

(define (start! program home configuration data cache)
  (%start! program home configuration data cache #f))

;; Only the Tuna that installs writes the install's libraries, since other
;; Tunas run from them.
(define (start-install! program home configuration data cache)
  (%start! program home configuration data cache #t))

(define (installed) (installed-plugins))

(define (%left-out-cause plugin)
  (let ([library (unavailable-library-of plugin)])
    (if library
        (format "it needs library ~a" library)
        (build-failure-of plugin))))

;; A library or build that fails leaves out only the plugins that need
;; it, so it is told on standard output rather than reported: a report
;; fails make exe, which must succeed without, say, the terminal's tools.
(define (install-all!)
  (for-each
    (lambda (failure)
      (printf "library ~a could not be installed: ~a\n" (car failure) (failure-text (cdr failure))))
    (install-own-libraries!))
  (let-values ([(left-out kept)
                (partition (lambda (id) (reached-left-out (list id))) (own-plugin-ids))])
    (for-each
      (lambda (id)
        (printf "plugin ~a is left out: ~a\n" id (%left-out-cause (reached-left-out (list id)))))
      left-out)
    (flush-output-port (current-output-port))
    (let ([loaded? #t])
      (call-as-owner (make-owner '(install))
        (lambda ()
          (for-each
            (lambda (name)
              (let ([form `(import ,name)])
                (unless (eq? (call-reporting form (lambda () (%evaluate form) #t) void) #t)
                  (set! loaded? #f))))
            (append (map list kept) (test-library-names)))))
      loaded?)))

(define (configuration-owner)
  (or (unbox %configuration) (assertion-violation 'plugins:configuration-owner "the configuration has not been read")))
(define (commit id) (plugin-commit id))
(define (install! line) (install-plugin! line))
(define update!
  (case-lambda
    [(id) (update-plugin! id)]
    [(id commit) (update-plugin! id commit)]))
(define (remove! id) (remove-plugin! id))
(define (remove-unused!) (remove-unused-plugins!))
(define (module-source name) (module-plugin-source name))

;;; Evaluating top-level forms

(define (%unwrap x) (if (annotation? x) (annotation-stripped x) x))
(define (%parts x) (if (annotation? x) (annotation-expression x) x))

(define (%top-level-imports form)
  (let ([form (%unwrap form)])
    (cond
      [(and (pair? form) (eq? (car form) 'import) (list? form))
       (filter values (map import-spec-library (cdr form)))]
      [(and (pair? form) (eq? (car form) 'begin) (list? form))
       (apply append (map %top-level-imports (cdr form)))]
      [else '()])))

;; A library built into Chez, such as (scheme), wins over a file of the
;; same name.
(define (%tuna-module? name)
  (let ([source (module-file-of name)])
    (and source (tuna-file? source)
         (not (and (member name (library-list)) (not (library-object-filename name)))))))

;; A module is loaded before the form that imports it compiles: a load
;; waits while an operation on modules is under way, where an import would
;; raise, and an unloaded module loads again as a new instance.
(define (%evaluate form)
  (%check-left-out (%top-level-imports form))
  (let ([imports (filter %tuna-module? (%top-level-imports form))])
    (for-each (lambda (name) (unless (module-owner name) (load-module! name))) imports)
    (when (eq? (current-owner) (unbox %configuration))
      (set-box! %imported (append (unbox %imported) imports)))
    (parameterize ([generate-inspector-information #f])
      (eval form (interaction-environment)))))

(define %configuration (box #f))
(define %imported (box '()))

(define-condition-type &left-out &error %make-left-out left-out?
  (plugin left-out-plugin) (library left-out-library))

(define (%check-left-out names)
  (for-each
    (lambda (name)
      (let ([plugin (reached-left-out name)])
        (when plugin
          (raise
            (condition (%make-left-out plugin (unavailable-library-of plugin)) (make-who-condition 'import)
              (make-message-condition
                (format "plugin ~a is left out of Tuna's install: ~a" plugin (%left-out-cause plugin))))))))
    names))

;; A line is data that eval-form reads from a top-level form, so a line
;; the expander meets is a mistake to name.
(define-values ()
  (begin
    (eval '(define-syntax use-plugin
             (lambda (x)
               (syntax-violation 'use-plugin
                 "expected an id and clauses (git url), (commit hex), (branch name), (dir path) or (local folder), then (config form ...) only in a top-level line"
                 x)))
          (interaction-environment))
    (eval '(define-syntax plugin
             (lambda (x)
               (syntax-violation 'plugin "a plugin line outside an index's main module" x)))
          (interaction-environment))
    (values)))

(define (eval-form form)
  (let ([datum (%unwrap form)])
    ;; The configuration's file was read as data before it ran; a line
    ;; evaluated as the configuration's from elsewhere is read here.
    (if (eq? (current-owner) (unbox %configuration))
        (when (and (plugin-line? datum) (not (configuration-line (line-id datum))))
          (read-configuration-line! datum))
        (read-repl-line! datum))
    (raise-line-failure datum)
    (cond
      [(library-line? datum) (void)]
      [(plugin-line? datum)
       (unless (index-module? (list (line-id datum)))
         (%evaluate `(import (,(line-id datum)))))
       (let ([config (assq 'config (cddr datum))])
         (when config
           (for-each (lambda (f) (call-reporting f (lambda () (%eval-config-form f)) void))
                     (cdr (%parts (car (last-pair (%parts form))))))))]
      [else (%evaluate form)])))

(define (%eval-config-form form)
  (let ([datum (%unwrap form)])
    (cond
      [(library-line? datum)
       (errorf 'library "a library line goes at the top level of the configuration or the REPL")]
      [(plugin-line? datum)
       (errorf 'use-plugin "a use-plugin line goes at the top level of the configuration or the REPL")]
      [else (eval-form form)])))

;; A raise at run time carries no form, so the report of one from a form
;; read from a file names the form and its position. A cancel is the
;; task's, so it goes on.
(define (call-reporting form thunk after-report)
  (unless (procedure? thunk) (assertion-violation 'plugins:call-reporting "not a procedure" thunk))
  (unless (procedure? after-report) (assertion-violation 'plugins:call-reporting "not a procedure" after-report))
  (let ([warned '()])
    (call/cc
      (lambda (k)
        (with-exception-handler
          (lambda (c)
            (cond
              [(cancelled? c) (raise-continuable c)]
              ;; Compiling a library compiles its body twice, so one warning
              ;; can be raised twice; report each message once.
              [(and (warning? c) (not (serious-condition? c)))
               (let ([text (condition-text c)])
                 (unless (member text warned)
                   (set! warned (cons text warned))
                   (report c)))]
              [else
               (report
                 (if (or (not form) (not (condition? c)) (source-condition? c) (syntax-violation? c)
                         (not (syntax->annotation form)))
                     c
                     (condition c (make-source-condition form))))
               (k (after-report))]))
          thunk)))))

(define (%read-annotated-forms path consume)
  (let ([sfd (call-with-port (open-file-input-port path) (lambda (p) (make-source-file-descriptor path p)))])
    (call-with-port (open-input-file path)
      (lambda (p)
        (let loop ([position 0])
          (let-values ([(form end) (get-datum/annotations p sfd position)])
            (unless (eof-object? form)
              (consume form)
              (loop end))))))))

(define (file-forms path)
  (unless (string? path) (assertion-violation 'plugins:file-forms "not a string" path))
  (let ([forms '()])
    (%read-annotated-forms path (lambda (form) (set! forms (cons form forms))))
    (reverse forms)))

(define-public (configuration-loaded)
  "Called once the configuration has been evaluated."
  (void))

;; A read error ends the configuration: after it, where the next form
;; starts is unknown.
(define (%read-configuration!)
  (let ([old (unbox %configuration)])
    (when old (unload-owner! old)))
  (let ([o (make-owner '(init))])
    (set-box! %configuration o)
    (set-box! %imported '())
    (call-as-owner o
      (lambda ()
        (call-reporting #f
          (lambda ()
            (read-configuration-lines!)
            (let ([file (%configuration-file)])
              (when (file-exists? file)
                (%read-annotated-forms file
                  (lambda (form) (call-reporting form (lambda () (eval-form form)) void))))))
          void)))
    (configuration-loaded)))

;;; The turn

;; The operations the plugin manager mediates, and the reads of init.ss,
;; run one at a time, each holding the turn; the configuration is read
;; again only once the operation that unloaded it is done.
(define %holder (box #f))
(define %waiting (box '()))

(define (%take-turn!)
  (let ([me (current-task)])
    (let wait ()
      (when (unbox %holder)
        (suspend (lambda (resume) (set-box! %waiting (append (unbox %waiting) (list resume)))))
        (wait)))
    (set-box! %holder me)))

(define (%give-turn! from)
  (when (eq? (unbox %holder) from)
    (set-box! %holder #f)
    (let ([ws (unbox %waiting)])
      (set-box! %waiting '())
      (for-each (lambda (resume) (resume void)) ws))))

(define (%hand-turn! from to)
  (when (eq? (unbox %holder) from)
    (set-box! %holder to)))

;; A task's winders also run each time it pauses, while its state is
;; paused; the turn moves only when the code is left.
(define (%on-leave thunk leave)
  (dynamic-wind
    void
    thunk
    (lambda () (unless (eq? (task-state (current-task)) 'paused) (leave)))))

(define (load-configuration!)
  (let ([me (current-task)])
    (%on-leave
      (lambda () (%take-turn!) (%read-configuration!))
      (lambda () (%give-turn! me)))))

(define (%reader)
  (spawn-task
    (lambda (restore)
      (let ([me (current-task)])
        (%on-leave %read-configuration! (lambda () (%give-turn! me)))))))

;; A loaded module's imports are those its instance was compiled with,
;; which the kernel's reload follows, whatever its source says now.
(define (%with-importers names)
  (let ([loaded (loaded-modules)])
    (let loop ([found names])
      (let ([more (filter (lambda (name)
                            (and (not (member name found))
                                 (exists (lambda (import) (member import found))
                                         (library-requirements name (library-requirements-options import)))))
                          loaded)])
        (if (null? more) found (loop (append found more)))))))

(define %repl (box #f))

(define (repl-owner)
  (let ([o (unbox %repl)])
    (if (and o (owner-live? o))
        o
        (let ([o (make-owner '(repl))])
          (set-box! %repl o)
          o))))

;; The configuration imports what its lines name, so an operation that
;; unloads one of those modules unloads the configuration first and reads
;; it again after, as a fresh start would. One that unloads the plugin
;; manager leaves the read to start's new body, and keeps the turn, so the
;; old instance mediates nothing after it.
(define (%mediate unloads thunk)
  (let ([self? (member '(plugins) unloads)])
    (if (not (or self? (exists (lambda (name) (member name (unbox %imported))) unloads)))
        (thunk)
        (let ([me (current-task)] [reader #f] [asked? #f])
          (%on-leave
            (lambda ()
              (%take-turn!)
              ;; An unload once asked for stands, so a cut that lands while
              ;; the configuration's unload waits still leaves it to read.
              (set! asked? #t)
              (let ([config (unbox %configuration)])
                (when (and config (owner-live? config)) (unload-owner! config)))
              ;; The new instance cannot find this one's REPL owner, and
              ;; making an owner of a live name raises.
              (when self?
                (let ([r (unbox %repl)]) (when (and r (owner-live? r)) (unload-owner! r))))
              (call-with-values thunk
                (lambda results
                  (unless self?
                    (set! reader (%reader))
                    (join-task reader))
                  (apply values results))))
            (lambda ()
              (cond
                [self? (void)]
                [(and reader (not (eq? (task-state reader) 'done))) (%hand-turn! me reader)]
                [(and asked? (not reader)) (let ([r (%reader)]) (%hand-turn! me r))]
                [else (%give-turn! me)])))))))

(advice-add! reload-modules!
  (lambda (next names)
    (if (and (list? names) (for-all list? names))
        (%mediate (%with-importers names) (lambda () (next names)))
        (next names))))

(advice-add! unload-owner!
  (lambda (next owner)
    (let ([name (and (owner? owner) (owner-name owner))])
      (if (and name (eq? (module-owner name) owner))
          (%mediate (%with-importers (list name)) (lambda () (next owner)))
          (next owner)))))
