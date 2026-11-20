#!tuna
(import (prog) (modes) (auto-mode) (buffers) (document) (files) (jobs) (faces) (syntax)
        (chez-scheme highlight))

(define-table keymap
  "Keys in Scheme buffers.")

(define-hook mode-hook
  "Called in each buffer that turns on chez-scheme:mode, after prog:mode-hook.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Scheme")
  (keymap keymap)
  (hook mode-hook))

(buffers:define-layer highlights (priority -10) (sticky after) (evaporate))

(define-enumeration binding-kind (procedure syntax variable) binding-kinds)

(define-record-type name
  (sealed #t)
  (fields spelling export library kind))

(jobs:define-worker (%highlighter input emit receive)
  (import (chez-scheme highlight))
  (serve input emit receive))

(define %face-roles
  (list (cons 'comment faces:comment) (cons 'documentation faces:comment.documentation)
        (cons 'string faces:string) (cons 'escape faces:string.escape)
        (cons 'character faces:character) (cons 'number faces:number) (cons 'boolean faces:boolean)
        (cons 'directive faces:keyword.directive) (cons 'object faces:constant.builtin)
        (cons 'punctuation faces:punctuation.special) (cons 'quoted faces:string.special.symbol)
        (cons 'function faces:function) (cons 'type faces:type) (cons 'module faces:module)
        (cons 'builtin faces:function.builtin) (cons 'keyword faces:keyword)))

(module %internals
  (open-ended-marks mismatched-marks no-marks lexeme-class start-highlighting! stop-highlighting!
   send-edit! tell-bracket-users! note-changed! rebuild-stale-names! highlighted-buffers
   check-main-thread repl-libraries repl-names-and-table buffer-names-and-table)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define no-marks (syntax:lexeme-marks))
  (define open-ended-marks (syntax:lexeme-marks open-ended))
  (define mismatched-marks (syntax:lexeme-marks mismatched))

  (define (lexeme-class kind)
    (case kind
      [(open) (syntax:class open)]
      [(close) (syntax:class close)]
      [(prefix) (syntax:class prefix)]
      [(string) (syntax:class string)]
      [(line-comment block-comment datum-comment directive) (syntax:class comment)]
      [else (syntax:class atom)]))

  (define-record-type highlighting
    (sealed #t)
    (fields buffer job (mutable brackets?) (mutable scope) (mutable names) (mutable table)))

  (define jobs (make-eq-hashtable))

  (define (highlighted-buffers) (vector->list (hashtable-keys jobs)))

  (define (clear-spans! buffer type)
    (when (buffers:live? buffer)
      (let ([layer (buffers:layer buffer type)])
        (buffers:set-spans! layer 0 (document:length (buffers:document buffer)) '()))))

  (define (set-update! buffer type version update)
    (when update
      (buffers:set-spans! (buffers:layer buffer type) (car update) (cadr update) (caddr update) version)))

  (define (current? h)
    (eq? (hashtable-ref jobs (highlighting-buffer h) #f) h))

  (define (receive! h result)
    (when (and (current? h) (buffers:live? (highlighting-buffer h)))
      (let ([buffer (highlighting-buffer h)])
        (case (car result)
          [(spans)
           (set-update! buffer highlights (cadr result) (caddr result))
           (when (highlighting-brackets? h)
             (set-update! buffer syntax:brackets (cadr result) (cadddr result)))]
          [(scope)
           (highlighting-scope-set! h (cdr result))
           (send-names! h)]))))

  (define (forget! h)
    (let ([buffer (highlighting-buffer h)])
      (hashtable-delete! jobs buffer)
      (clear-spans! buffer highlights)
      (clear-spans! buffer syntax:brackets)))

  (define (start-highlighting! buffer)
    (unless (hashtable-ref jobs buffer #f)
      (let* ([brackets? (syntax:brackets-used? buffer)] [h #f]
             [job (jobs:start %highlighter
                    (list (buffers:version buffer) (buffers:document buffer) brackets? %face-roles)
                    (lambda (result) (receive! h result))
                    ;; A job that raised has ended; forgetting it lets the
                    ;; next mode set start another.
                    (lambda (ended) (when (current? h) (forget! h))))])
        (set! h (make-highlighting buffer job brackets? #f #f #f))
        (hashtable-set! jobs buffer h))))

  (define (stop-highlighting! buffer)
    (let ([h (hashtable-ref jobs buffer #f)])
      (when h
        (forget! h)
        (jobs:stop! (highlighting-job h)))))

  (define (send-edit! buffer edit)
    (let ([h (hashtable-ref jobs buffer #f)])
      (when h
        (jobs:send! (highlighting-job h)
                    (cons* 'edit (buffers:version buffer) (buffers:edit-start edit)
                           (buffers:piece-length (buffers:edit-removed edit))
                           (buffers:piece-length (buffers:edit-inserted edit))
                           (buffers:document buffer))))))

  (define (tell-bracket-users!)
    (vector-for-each
      (lambda (h)
        (let* ([buffer (highlighting-buffer h)] [used? (syntax:brackets-used? buffer)])
          (unless (eq? used? (highlighting-brackets? h))
            (highlighting-brackets?-set! h used?)
            (jobs:send! (highlighting-job h) (cons 'brackets used?))
            (unless used? (clear-spans! buffer syntax:brackets)))))
      (hashtable-values jobs)))

  ;; One environment per library load, since Chez never frees an
  ;; environment.
  (define classes (make-hashtable equal-hash equal?))
  (define stale '())

  (define (module-prefix name)
    (call-with-string-output-port
      (lambda (p)
        (let loop ([parts name])
          (display (car parts) p)
          (unless (null? (cdr parts))
            (put-char p #\/)
            (loop (cdr parts))))
        (put-char p #\:))))

  (define (string-prefix? prefix s)
    (let ([n (string-length prefix)])
      (and (fx<= n (string-length s)) (string=? prefix (substring s 0 n)))))

  (define (without-prefix name prefix)
    (let ([s (symbol->string name)])
      (if (and prefix (string-prefix? prefix s))
          (substring s (string-length prefix) (string-length s))
          s)))

  ;; Chez calls every changeable definition a keyword, so the module's own
  ;; record of its definitions tells them from syntax. The kernel adds
  ;; %scope to every module's exports, and no module defines it.
  (define (classify name)
    (let* ([module? (module-name? name)]
           [prefix (and module? (module-prefix name))]
           [scope-export (and module? (string->symbol (string-append prefix "%scope")))]
           [definitions (if module?
                            (fold-left (lambda (acc change) (if (eq? (car change) 'define) (cons (cadr change) acc) acc))
                                       '() (module-changes name))
                            '())]
           [env (environment name)]
           [kind-of (lambda (v) (if (procedure? v) 'procedure 'variable))])
      (fold-left
        (lambda (acc export)
          (cond
            [(eq? export scope-export) acc]
            [(top-level-bound? export env) (cons (cons export (kind-of (top-level-value export env))) acc)]
            [(memq export definitions)
             (cons (cons export (kind-of (eval-in-module (string->symbol (without-prefix export prefix)) name))) acc)]
            [else (cons (cons export 'syntax) acc)]))
        '() (library-exports name))))

  (define (library-classes name)
    (if (if (module-name? name) (member name (loaded-modules)) (member name (library-list)))
        (or (hashtable-ref classes name #f)
            (let ([found (guard (c [(not (quit-condition? c)) (report c) '()]) (classify name))])
              (hashtable-set! classes name found)
              found))
        '()))

  ;; Chez's library list keeps a module after it unloads; a module is
  ;; known by the %scope macro every module exports.
  (define (module-name? name)
    (and (member name (library-list))
         (memq (string->symbol (string-append (module-prefix name) "%scope")) (library-exports name))
         #t))

  (define (spec-library spec)
    (let loop ([parts spec])
      (cond
        [(null? parts) '()]
        [(symbol? (car parts)) (cons (car parts) (loop (cdr parts)))]
        [else '()])))

  (define (rename-pairs pairs)
    (filter (lambda (p) (and (list? p) (fx= (length p) 2) (symbol? (car p)) (symbol? (cadr p)))) pairs))

  (define (private-export? export library)
    (let ([plain (without-prefix export (and (module-name? library) (module-prefix library)))])
      (and (fx> (string-length plain) 0) (char=? (string-ref plain 0) #\%))))

  (define (library-names library)
    (map (lambda (entry) (make-name (car entry) (car entry) library (cdr entry))) (library-classes library)))

  (define (respelled entry spelling)
    (make-name spelling (name-export entry) (name-library entry) (name-kind entry)))

  ;; A module's file is not offered its imports' % names, since one
  ;; plugin's code keeps off another's helpers.
  (define (spec-names spec module-file?)
    (define (base library)
      (if module-file?
          (filter (lambda (entry) (not (private-export? (name-export entry) library))) (library-names library))
          (library-names library)))
    (cond
      [(not (and (pair? spec) (list? spec))) '()]
      [(and (memq (car spec) '(only except prefix add-prefix drop-prefix rename alias for library))
            (pair? (cdr spec)))
       (let ([inner (lambda () (spec-names (cadr spec) module-file?))] [args (cddr spec)])
         (case (car spec)
           [(only) (filter (lambda (entry) (memq (name-spelling entry) args)) (inner))]
           [(except) (filter (lambda (entry) (not (memq (name-spelling entry) args))) (inner))]
           [(prefix add-prefix)
            (if (and (pair? args) (symbol? (car args)))
                (map (lambda (entry)
                       (respelled entry (string->symbol (string-append (symbol->string (car args))
                                                                       (symbol->string (name-spelling entry))))))
                     (inner))
                (inner))]
           [(drop-prefix)
            (if (and (pair? args) (symbol? (car args)))
                (let ([prefix (symbol->string (car args))])
                  (map (lambda (entry) (respelled entry (string->symbol (without-prefix (name-spelling entry) prefix))))
                       (inner)))
                (inner))]
           [(rename)
            (let ([pairs (rename-pairs args)])
              (map (lambda (entry)
                     (let ([p (assq (name-spelling entry) pairs)])
                       (if p (respelled entry (cadr p)) entry)))
                   (inner)))]
           [(alias)
            (let ([names (inner)])
              (append names
                      (fold-left (lambda (acc p)
                                   (let ([entry (find (lambda (e) (eq? (name-spelling e) (car p))) names)])
                                     (if entry (cons (respelled entry (cadr p)) acc) acc)))
                                 '() (rename-pairs args))))]
           [(for) (inner)]
           [(library) (let ([name (spec-library (cadr spec))]) (if (pair? name) (base name) '()))]))]
      [else (let ([name (spec-library spec)]) (if (pair? name) (base name) '()))]))

  (define (file-module path)
    (and path
         (exists
           (lambda (folders)
             (let ([folder (string-append (car folders) "/")])
               (and (string-prefix? folder path)
                    (exists
                      (lambda (extension)
                        (let* ([extension (car extension)] [n (string-length path)] [m (string-length extension)])
                          (and (fx> n (fx+ (string-length folder) m))
                               (string=? (substring path (fx- n m) n) extension)
                               (let ([name (map string->symbol
                                                (split (substring path (string-length folder) (fx- n m))))])
                                 (and (member name (loaded-modules))
                                      (let-values ([(source object found?)
                                                    ((library-search-handler) 'import name (library-directories) (library-extensions))])
                                        (and (equal? source path) name)))))))
                      (library-extensions)))))
           (library-directories))))

  (define (split s)
    (let loop ([i 0] [start 0] [acc '()])
      (cond
        [(fx= i (string-length s)) (reverse (cons (substring s start i) acc))]
        [(char=? (string-ref s i) #\/) (loop (fx+ i 1) (fx+ i 1) (cons (substring s start i) acc))]
        [else (loop (fx+ i 1) start acc)])))

  (define (own-names h)
    (let* ([scope (highlighting-scope h)]
           [own (or (and (pair? (cadr scope)) (cadr scope))
                    (file-module (files:path (highlighting-buffer h))))])
      (if own
          (let ([prefix (and (module-name? own) (module-prefix own))])
            (map (lambda (entry) (respelled entry (string->symbol (without-prefix (name-export entry) prefix))))
                 (library-names own)))
          '())))

  (define (repl-libraries)
    (filter (lambda (name) (member name (library-list)))
            (append '((tuna core replaced) (chezscheme) (tuna) (tuna base) (tuna plugins) (tuna eval))
                    (loaded-modules))))

  ;; The first name for a spelling is the one Chez resolves, so the
  ;; sources come in that order and later ones are dropped.
  (define (names-and-table sources)
    (let ([table (make-eq-hashtable)])
      (for-each
        (lambda (names)
          (for-each
            (lambda (entry)
              (unless (eq-hashtable-contains? table (name-spelling entry))
                (eq-hashtable-set! table (name-spelling entry) entry)))
            names))
        sources)
      (let ([names (vector-sort (lambda (a b) (string<? (symbol->string (name-spelling a)) (symbol->string (name-spelling b))))
                                (hashtable-values table))])
        (cons names table))))

  (define repl #f)

  (define (repl-names-and-table)
    (or repl
        (let ([found (names-and-table (map library-names (repl-libraries)))])
          (set! repl found)
          found)))

  (define (scope-sources h)
    (let ([scope (highlighting-scope h)])
      (cons (own-names h)
            (map (lambda (spec)
                   (if (eq? spec 'repl)
                       (vector->list (car (repl-names-and-table)))
                       (spec-names spec (caddr scope))))
                 (car scope)))))

  (define (send-names! h)
    (when (highlighting-scope h)
      (let ([found (names-and-table (scope-sources h))])
        (highlighting-names-set! h (car found))
        (highlighting-table-set! h (cdr found))
        (jobs:send! (highlighting-job h)
                    (cons 'names
                          (jobs:freeze
                            (list->vector
                              (fold-right
                                (lambda (entry acc)
                                  (if (eq? (name-kind entry) 'variable)
                                      acc
                                      (cons (cons (name-spelling entry) (name-kind entry)) acc)))
                                '() (vector->list (car found))))))))))

  (define (buffer-names-and-table buffer)
    (let ([h (hashtable-ref jobs buffer #f)])
      (if (and h (highlighting-names h))
          (cons (highlighting-names h) (highlighting-table h))
          (repl-names-and-table))))

  (define (note-changed! name)
    (hashtable-delete! classes name)
    (set! repl #f)
    (set! stale (cons name stale)))

  ;; The kernel tells of a load, not of an unload, and every unload but
  ;; those at exit happens in a batch, so the batch's end finds the
  ;; modules gone since the last.
  (define seen-modules '())

  (define (note-unloaded!)
    (let ([now (loaded-modules)])
      (unless (equal? now seen-modules)
        (for-each (lambda (name) (unless (member name now) (note-changed! name))) seen-modules)
        (set! seen-modules now))))

  (define (uses? h name)
    (let ([scope (highlighting-scope h)])
      (and scope
           (or (memq 'repl (car scope))
               (equal? (cadr scope) name)
               (exists (lambda (spec) (equal? (spec-library-of spec) name)) (car scope))
               (equal? (file-module (files:path (highlighting-buffer h))) name))
           #t)))

  (define (spec-library-of spec)
    (if (and (pair? spec) (list? spec)
             (memq (car spec) '(only except prefix add-prefix drop-prefix rename alias for library))
             (pair? (cdr spec)))
        (spec-library-of (cadr spec))
        (and (pair? spec) (list? spec) (spec-library spec))))

  (define (rebuild-stale-names!)
    (note-unloaded!)
    (unless (null? stale)
      (let ([loaded stale])
        (set! stale '())
        (vector-for-each
          (lambda (h)
            (when (exists (lambda (name) (uses? h name)) loaded)
              (send-names! h)))
          (hashtable-values jobs))))))

(import %internals)

(define (tuna-libraries)
  (check-main-thread 'chez-scheme:tuna-libraries)
  (repl-libraries))

(define (repl-names)
  (check-main-thread 'chez-scheme:repl-names)
  (car (repl-names-and-table)))

(define (names buffer)
  (check-main-thread 'chez-scheme:names)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'chez-scheme:names "not a buffer" buffer))
  (car (buffer-names-and-table buffer)))

(define (find-name buffer spelling)
  (check-main-thread 'chez-scheme:find-name)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'chez-scheme:find-name "not a buffer" buffer))
  (unless (symbol? spelling)
    (assertion-violation 'chez-scheme:find-name "not a symbol" spelling))
  (eq-hashtable-ref (cdr (buffer-names-and-table buffer)) spelling #f))

(define (lexer document)
  (unless (document? document)
    (assertion-violation 'chez-scheme:lexer "not a document" document))
  (let ([acc '()])
    (lex-document document
      (lambda (kind start end depth open-ended? mismatched?)
        (set! acc (cons (syntax:make-lexeme (lexeme-class kind) start end depth
                          (cond [open-ended? open-ended-marks] [mismatched? mismatched-marks] [else no-marks]))
                        acc))))
    (list->vector (reverse acc))))

(define (%highlight-in-mode buffer)
  (if (modes:derived? (modes:major-mode buffer) mode)
      (start-highlighting! buffer)
      (stop-highlighting! buffer)))

(define (%send-edit buffer edit) (send-edit! buffer edit))

(define (%note-module-loaded loaded name)
  (loaded name)
  (note-changed! name))

(define (%rebuild-names ended)
  (ended)
  (as-module (this-module) (rebuild-stale-names!)))

(table-set! syntax:lexers mode lexer)
(table-set! syntax:symbol-characters mode "!$%&*/:<=>?^_~+-.@")
(for-each (lambda (name) (table-set! auto-mode:file-names name mode))
          '("sls" "ss" "sps" "scm" "sch" "sld"))
(for-each (lambda (name) (table-set! auto-mode:interpreters name mode))
          '("tuna" "scheme" "petite" "scheme-script" "r6rs" "chezscheme"))
(add-hook! modes:major-mode-changed %highlight-in-mode)
(add-hook! modes:delayed-mode-changed %highlight-in-mode)
(add-hook! buffers:killed stop-highlighting!)
(add-hook! buffers:after-edit %send-edit)
(add-hook! syntax:bracket-users-changed tell-bracket-users!)
(advice-add! module-loaded %note-module-loaded)
(advice-add! batch-ended %rebuild-names)
(on-unload (lambda () (for-each stop-highlighting! (highlighted-buffers))))
(for-each (lambda (buffer)
            (when (modes:derived? (modes:major-mode buffer) mode)
              (start-highlighting! buffer)))
          (buffers:all))
