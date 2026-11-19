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
   send-edit! tell-bracket-users! note-loaded! rebuild-stale-names! highlighted-buffers)

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
    (fields buffer job (mutable brackets?) (mutable scope)))

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
        (set! h (make-highlighting buffer job brackets? #f))
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
  ;; record of its definitions tells them from syntax.
  (define (classify name)
    (let* ([module? (module-name? name)]
           [prefix (and module? (module-prefix name))]
           [definitions (if module?
                            (fold-left (lambda (acc change) (if (eq? (car change) 'define) (cons (cadr change) acc) acc))
                                       '() (module-changes name))
                            '())]
           [env (environment name)])
      (fold-left
        (lambda (acc export)
          (let ([plain (without-prefix export prefix)])
            (cond
              [(and (fx> (string-length plain) 0) (char=? (string-ref plain 0) #\%)) acc]
              [(top-level-bound? export env)
               (if (procedure? (top-level-value export env)) (cons (cons export 'procedure) acc) acc)]
              [(memq export definitions)
               (if (procedure? (eval-in-module (string->symbol plain) name)) (cons (cons export 'procedure) acc) acc)]
              [else (cons (cons export 'syntax) acc)])))
        '() (library-exports name))))

  (define (library-classes name)
    (or (hashtable-ref classes name #f)
        (let ([found (if (if (module-name? name) (member name (loaded-modules)) (member name (library-list)))
                         (guard (c [(not (quit-condition? c)) (report c) '()]) (classify name))
                         '())])
          (hashtable-set! classes name found)
          found)))

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

  (define (spec-names spec)
    (cond
      [(not (and (pair? spec) (list? spec))) '()]
      [(and (memq (car spec) '(only except prefix add-prefix drop-prefix rename alias for library))
            (pair? (cdr spec)))
       (let ([inner (lambda () (spec-names (cadr spec)))] [args (cddr spec)])
         (case (car spec)
           [(only) (filter (lambda (entry) (memq (car entry) args)) (inner))]
           [(except) (filter (lambda (entry) (not (memq (car entry) args))) (inner))]
           [(prefix add-prefix)
            (if (and (pair? args) (symbol? (car args)))
                (map (lambda (entry)
                       (cons (string->symbol (string-append (symbol->string (car args)) (symbol->string (car entry))))
                             (cdr entry)))
                     (inner))
                (inner))]
           [(drop-prefix)
            (if (and (pair? args) (symbol? (car args)))
                (let ([prefix (symbol->string (car args))])
                  (map (lambda (entry) (cons (string->symbol (without-prefix (car entry) prefix)) (cdr entry))) (inner)))
                (inner))]
           [(rename)
            (let ([pairs (rename-pairs args)])
              (map (lambda (entry)
                     (let ([p (assq (car entry) pairs)])
                       (if p (cons (cadr p) (cdr entry)) entry)))
                   (inner)))]
           [(alias)
            (let ([names (inner)])
              (append names
                      (fold-left (lambda (acc p)
                                   (let ([entry (assq (car p) names)])
                                     (if entry (cons (cons (cadr p) (cdr entry)) acc) acc)))
                                 '() (rename-pairs args))))]
           [(for) (inner)]
           [(library) (let ([name (spec-library (cadr spec))]) (if (pair? name) (library-classes name) '()))]))]
      [else (let ([name (spec-library spec)]) (if (pair? name) (library-classes name) '()))]))

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
            (map (lambda (entry) (cons (string->symbol (without-prefix (car entry) prefix)) (cdr entry)))
                 (library-classes own)))
          '())))

  (define (scope-names h)
    (let ([specs (car (highlighting-scope h))])
      (if (eq? specs 'repl)
          (apply append (library-classes '(chezscheme)) (library-classes '(tuna))
                 (map library-classes (loaded-modules)))
          (apply append (map spec-names specs)))))

  (define (send-names! h)
    (when (highlighting-scope h)
      (let ([table (make-eq-hashtable)])
        (for-each (lambda (entry) (hashtable-set! table (car entry) (cdr entry)))
                  (append (scope-names h) (own-names h)))
        (let-values ([(names kinds) (hashtable-entries table)])
          (jobs:send! (highlighting-job h)
                      (cons 'names (jobs:freeze (vector-map cons names kinds))))))))

  (define (note-loaded! name)
    (hashtable-delete! classes name)
    (set! stale (cons name stale)))

  (define (uses? h name)
    (let ([scope (highlighting-scope h)])
      (and scope
           (or (eq? (car scope) 'repl)
               (equal? (cadr scope) name)
               (exists (lambda (spec) (equal? (spec-library-of spec) name)) (car scope))
               (equal? (file-module (files:path (highlighting-buffer h))) name)))))

  (define (spec-library-of spec)
    (if (and (pair? spec) (list? spec)
             (memq (car spec) '(only except prefix add-prefix drop-prefix rename alias for library))
             (pair? (cdr spec)))
        (spec-library-of (cadr spec))
        (and (pair? spec) (list? spec) (spec-library spec))))

  (define (rebuild-stale-names!)
    (unless (null? stale)
      (let ([loaded stale])
        (set! stale '())
        (vector-for-each
          (lambda (h)
            (when (exists (lambda (name) (uses? h name)) loaded)
              (send-names! h)))
          (hashtable-values jobs))))))

(import %internals)

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
  (note-loaded! name))

(define (%rebuild-names ended)
  (ended)
  (as-module (this-module) (rebuild-stale-names!)))

(table-set! syntax:lexers mode lexer)
(for-each (lambda (name) (table-set! auto-mode:file-names name mode))
          '("sls" "ss" "sps" "scm" "sch" "sld"))
(for-each (lambda (name) (table-set! auto-mode:interpreters name mode))
          '("tuna" "scheme" "petite" "scheme-script" "r6rs" "chezscheme"))
(add-hook! modes:major-mode-changed %highlight-in-mode)
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
