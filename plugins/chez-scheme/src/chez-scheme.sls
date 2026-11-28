#!tuna
(import (prog) (modes) (auto-mode) (buffers) (document) (files) (jobs) (faces) (syntax)
        (syntax-highlighting) (indentation) (chez-scheme highlight) (hooks) (options) (tables))

(define %self (current-owner))

(tables:define-table keymap
  "Keys in Scheme buffers.")

(hooks:define-hook mode-hook
  "Called in each buffer that turns on chez-scheme:mode, after prog:mode-hook.")

(modes:define-major-mode mode
  (parent prog:mode)
  (lighter "Scheme")
  (keymap keymap)
  (hook mode-hook)
  (language "scheme"))

(tables:define-table indent-rules
  "Maps a symbol to how a form with that head indents: the number of arguments it takes before its body; (indent-method defun), which puts the next line 2 columns past the opening bracket while the last argument before it is on the bracket's line; or a procedure of the buffer and the position of the form's opening bracket that returns that number.")

(define-enumeration indent-method (defun) %indent-methods)

(define-enumeration binding-kind (procedure syntax variable) binding-kinds)

(define-record-type name
  (sealed #t)
  (fields spelling export library kind))

(jobs:define-worker (%highlighter input emit receive)
  (import (syntax-highlighting job) (chez-scheme highlight))
  (serve input emit receive (make-highlight)))

(define %face-roles
  (list (cons 'comment faces:comment) (cons 'documentation faces:comment.documentation)
        (cons 'string faces:string) (cons 'escape faces:string.escape)
        (cons 'character faces:character) (cons 'number faces:number) (cons 'boolean faces:boolean)
        (cons 'directive faces:keyword.directive) (cons 'object faces:constant.builtin)
        (cons 'punctuation faces:punctuation.special) (cons 'quoted faces:string.special.symbol)
        (cons 'function faces:function) (cons 'type faces:type) (cons 'module faces:module)
        (cons 'builtin faces:function.builtin) (cons 'keyword faces:keyword)))

(module %internals
  (open-ended-marks mismatched-marks no-marks lexeme-class note-changed! drop-stale-names!
   check-main-thread repl-libraries repl-names-and-table buffer-names-and-table name-pairs)

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

  ;; The kernel adds %scope to every module's exports, and no module
  ;; defines it. A module's % procedures are not exported; its owner's
  ;; definitions name them.
  (define (classify name)
    (let* ([module? (module-name? name)]
           [prefix (and module? (module-prefix name))]
           [scope-export (and module? (string->symbol (string-append prefix "%scope")))]
           [env (environment name)]
           [kind-of (lambda (v) (if (procedure? v) 'procedure 'variable))])
      (fold-left
        (lambda (acc export)
          (cond
            [(eq? export scope-export) acc]
            [(top-level-bound? export env) (cons (cons export (kind-of (top-level-value export env))) acc)]
            [else (cons (cons export 'syntax) acc)]))
        (if module? (helpers name) '())
        (library-exports name))))

  (define (helpers name)
    (let ([owner (module-owner name)])
      (if owner
          (fold-left
            (lambda (acc change)
              (if (and (eq? (car change) 'define) (private-export? (caddr change) name))
                  (cons (cons (caddr change) 'procedure) acc)
                  acc))
            '() (owner-changes owner))
          '())))

  (define (library-classes name)
    (if (if (module-name? name) (member name (loaded-modules)) (member name (library-list)))
        (or (hashtable-ref classes name #f)
            (let ([found (guard (c [(not (cancelled? c)) (report c) '()]) (classify name))])
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
                                                    (default-library-search-handler 'import name (library-directories) (library-extensions))])
                                        (and (equal? source path) name)))))))
                      (library-extensions)))))
           (library-directories))))

  (define (split s)
    (let loop ([i 0] [start 0] [acc '()])
      (cond
        [(fx= i (string-length s)) (reverse (cons (substring s start i) acc))]
        [(char=? (string-ref s i) #\/) (loop (fx+ i 1) (fx+ i 1) (cons (substring s start i) acc))]
        [else (loop (fx+ i 1) start acc)])))

  (define (own-module scope buffer)
    (or (and (pair? (cadr scope)) (cadr scope))
        (file-module (files:path buffer))))

  (define (own-names own)
    (if own
        (let ([prefix (and (module-name? own) (module-prefix own))])
          (map (lambda (entry) (respelled entry (string->symbol (without-prefix (name-export entry) prefix))))
               (library-names own)))
        '()))

  (define (repl-libraries)
    (filter (lambda (name) (member name (library-list)))
            (append '((tuna replaced) (chezscheme) (tuna))
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

  (define (scope-sources scope own)
    (cons (own-names own)
          (map (lambda (spec)
                 (if (eq? spec 'repl)
                     (vector->list (car (repl-names-and-table)))
                     (spec-names spec (caddr scope))))
               (car scope))))

  (define-record-type scope-names
    (sealed #t)
    (fields scope own names table pairs))

  (define buffer-names (make-weak-eq-hashtable))

  (define (names-of buffer scope)
    (let ([own (own-module scope buffer)] [found (eq-hashtable-ref buffer-names buffer #f)])
      (if (and found (equal? (scope-names-scope found) scope) (equal? (scope-names-own found) own))
          found
          (let* ([sorted (names-and-table (scope-sources scope own))]
                 [made (make-scope-names scope own (car sorted) (cdr sorted)
                         (jobs:freeze
                           (list->vector
                             (fold-right
                               (lambda (entry acc)
                                 (if (eq? (name-kind entry) 'variable)
                                     acc
                                     (cons (cons (name-spelling entry) (name-kind entry)) acc)))
                               '() (vector->list (car sorted))))))])
            (eq-hashtable-set! buffer-names buffer made)
            made))))

  (define (name-pairs buffer scope)
    (scope-names-pairs (names-of buffer scope)))

  (define (buffer-names-and-table buffer)
    (let ([found (and (modes:derived? (modes:major-mode buffer) mode)
                      (eq-hashtable-ref buffer-names buffer #f))])
      (if found
          (cons (scope-names-names found) (scope-names-table found))
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

  (define (uses? found name)
    (let ([scope (scope-names-scope found)])
      (and (or (memq 'repl (car scope))
               (equal? (cadr scope) name)
               (exists (lambda (spec) (equal? (spec-library-of spec) name)) (car scope))
               (equal? (scope-names-own found) name))
           #t)))

  (define (spec-library-of spec)
    (if (and (pair? spec) (list? spec)
             (memq (car spec) '(only except prefix add-prefix drop-prefix rename alias for library))
             (pair? (cdr spec)))
        (spec-library-of (cadr spec))
        (and (pair? spec) (list? spec) (spec-library spec))))

  (define (drop-stale-names!)
    (note-unloaded!)
    (and (pair? stale)
         (let ([changed stale])
           (set! stale '())
           (vector-for-each
             (lambda (buffer)
               (when (exists (lambda (name) (uses? (eq-hashtable-ref buffer-names buffer #f) name)) changed)
                 (eq-hashtable-delete! buffer-names buffer)))
             (hashtable-keys buffer-names))
           #t))))

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

(define (%highlight-input buffer scope)
  (list %face-roles (syntax:brackets-used? buffer) (and scope (name-pairs buffer scope))))

(define (%note-module-loaded loaded instance)
  (loaded instance)
  (note-changed! (owner-name instance)))

(define (%update-names ended)
  (ended)
  (call-as-owner %self
    (lambda ()
      (when (drop-stale-names!)
        (syntax-highlighting:update!)))))

;; Emacs's Scheme mode puts a line holding only a one-semicolon comment
;; at this column.
(define %comment-column 40)

(define (%class? lexeme class) (eq? (syntax:lexeme-class lexeme) class))

(define-record-type (%sexp %make-sexp %sexp?)
  (sealed #t)
  (fields (immutable start %sexp-start) (immutable first %sexp-first)))

(define (%children buffer from to)
  (let loop ([ls (syntax:lexemes buffer from to)] [nest 0] [prefix #f] [acc '()])
    (if (null? ls)
        (reverse acc)
        (let ([l (car ls)])
          (cond
            [(%class? l (syntax:class comment)) (loop (cdr ls) nest prefix acc)]
            [(fx> nest 0)
             (loop (cdr ls)
                   (cond [(%class? l (syntax:class open)) (fx+ nest 1)] [(%class? l (syntax:class close)) (fx- nest 1)] [else nest])
                   prefix acc)]
            [(%class? l (syntax:class prefix)) (loop (cdr ls) 0 (or prefix (syntax:lexeme-start l)) acc)]
            [(%class? l (syntax:class close)) (loop (cdr ls) 0 #f acc)]
            [else
             (loop (cdr ls) (if (%class? l (syntax:class open)) 1 0) #f
                   (cons (%make-sexp (or prefix (syntax:lexeme-start l)) l) acc))])))))

(define (%line-end doc line)
  (if (fx< line (document:line doc (document:length doc)))
      (fx- (document:line-start doc (fx+ line 1)) 1)
      (document:length doc)))

;; As Emacs, the first sexp on a line is read from the line's start
;; whatever list holds it.
(define (%first-sexp-column buffer doc p)
  (let* ([line (document:line doc p)] [start (document:line-start doc line)])
    (let loop ([ls (syntax:lexemes buffer start (fx+ p 1))])
      (cond
        [(null? ls) (document:column doc p)]
        [(or (fx< (syntax:lexeme-start (car ls)) start)
             (%class? (car ls) (syntax:class comment))
             (%class? (car ls) (syntax:class close)))
         (loop (cdr ls))]
        [else (document:column doc (syntax:lexeme-start (car ls)))]))))

(define (%def-name? name)
  (and (fx> (string-length name) 3) (string=? (substring name 0 3) "def")))

(define (%after-last-colon name)
  (let loop ([i (fx- (string-length name) 1)])
    (cond
      [(fx< i 0) #f]
      [(char=? (string-ref name i) #\:) (substring name (fx+ i 1) (string-length name))]
      [else (loop (fx- i 1))])))

(define (%rule buffer name bracket)
  (let* ([plain (%after-last-colon name)]
         [rule (or (tables:ref indent-rules (string->symbol name) #f)
                   (and plain (tables:ref indent-rules (string->symbol plain) #f))
                   (and (or (%def-name? name) (and plain (%def-name? plain))) (indent-method defun)))])
    (if (procedure? rule)
        (let ([n (rule buffer bracket)])
          (unless (and (fixnum? n) (fx>= n 0))
            (assertion-violation 'chez-scheme:indenter "the rule did not return a count" name rule n))
          n)
        rule)))

;; Emacs's lisp-indent-specform: the first two distinguished arguments go
;; 4 columns in, so they stand apart from the body at 2.
(define (%special-column count bracket-column k normal)
  (let ([body (fx+ bracket-column 2)])
    (cond
      [(fx< k count) (if (fx<= k 1) (fx+ bracket-column 4) normal)]
      [(and (fx= count 0) (fx= k 0)) body]
      [(and (fx= k count) (fx<= body normal)) body]
      [else normal])))

(define (%list-column buffer doc open children)
  (let* ([bracket (fx- (syntax:lexeme-end open) 1)]
         [head (car children)]
         [last-start (%sexp-start (car (last-pair children)))]
         [later-line? (fx> (document:line doc last-start) (document:line doc (%sexp-start head)))]
         [normal (cond
                   [later-line? (%first-sexp-column buffer doc last-start)]
                   [(or (null? (cdr children)) (indentation:blank? (document:token doc (syntax:lexeme-end open))))
                    (document:column doc (%sexp-start head))]
                   [else (document:column doc (%sexp-start (cadr children)))])])
    (if (%class? (%sexp-first head) (syntax:class atom))
        (let* ([l (%sexp-first head)]
               [rule (%rule buffer (document:text doc (syntax:lexeme-start l) (syntax:lexeme-end l)) bracket)])
          (cond
            [(eq? rule (indent-method defun))
             (if (fx= (document:line doc last-start) (document:line doc bracket))
                 (fx+ (document:column doc bracket) 2)
                 normal)]
            [rule (%special-column rule (document:column doc bracket) (fx- (length children) 1) normal)]
            [else normal]))
        (if later-line? normal (document:column doc (%sexp-start head))))))

(define (%semicolons doc comment)
  (let ([end (syntax:lexeme-end comment)])
    (let loop ([p (syntax:lexeme-start comment)] [n 0])
      (if (and (fx< p end) (eqv? (document:token doc p) #\;)) (loop (fx+ p 1) (fx+ n 1)) n))))

(define (indenter buffer position)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'chez-scheme:indenter "not a buffer" buffer))
  (let ([doc (buffers:document buffer)])
    (unless (and (fixnum? position) (fx<= 0 position (document:length doc)))
      (assertion-violation 'chez-scheme:indenter "not a position in the buffer" position))
    (let ([within (syntax:lexeme-at buffer position)])
      (if (and within (or (%class? within (syntax:class string)) (%class? within (syntax:class comment))))
          #f
          (let* ([first (let ([ls (syntax:lexemes buffer position (%line-end doc (document:line doc position)))])
                          (and (pair? ls) (fx>= (syntax:lexeme-start (car ls)) position) (car ls)))]
                 [semicolons (if (and first (%class? first (syntax:class comment))) (%semicolons doc first) 0)])
            (cond
              [(fx>= semicolons 3) #f]
              [(fx= semicolons 1) %comment-column]
              [else
               (let ([openings (syntax:openings buffer position)])
                 (if (null? openings)
                     0
                     (let* ([open (car (last-pair openings))]
                            [children (%children buffer (syntax:lexeme-end open) position)])
                       (if (null? children)
                           (document:column doc (syntax:lexeme-end open))
                           (%list-column buffer doc open children)))))]))))))

;; Emacs's scheme-let-indent: a name right after let on its line makes
;; the let named, with its bindings a second argument before the body.
(define (%let-count buffer bracket)
  (let* ([doc (buffers:document buffer)]
         [ls (syntax:lexemes buffer (fx+ bracket 1) (%line-end doc (document:line doc bracket)))])
    (if (and (pair? ls) (pair? (cdr ls)) (%class? (cadr ls) (syntax:class atom))) 2 1)))

(tables:set! syntax:lexers mode lexer)
(tables:set! syntax:symbol-characters mode "!$%&*/:<=>?^_~+-.@")
(for-each (lambda (name) (tables:set! auto-mode:file-names name mode))
          '("sls" "ss" "sps" "scm" "sch" "sld"))
(for-each (lambda (name) (tables:set! auto-mode:interpreters name mode))
          '("tuna" "scheme" "petite" "scheme-script" "r6rs" "chezscheme"))
(tables:set! syntax-highlighting:highlighters mode
  (syntax-highlighting:make-highlighter %highlighter (list syntax-highlighting:faces syntax:brackets)
    %highlight-input))
(for-each (lambda (rule) (tables:set! indent-rules (car rule) (cdr rule)))
  `((begin . 0) (delay . 0) (sequence . 0) (case . 1) (lambda . 1) (let* . 1) (letrec . 1) (let-values . 1)
    (let*-values . 1) (and-let* . 1) (let-syntax . 1) (letrec-syntax . 1) (with-syntax . 1) (library . 1)
    (eval-when . 1) (when . 1) (unless . 1) (letrec* . 1) (parameterize . 1) (define-values . 1)
    (define-record-type . 1) (define-library . 1) (guard . 1) (syntax-rules . ,(indent-method defun)) (call-with-input-file . 1)
    (call-with-port . 1) (with-input-from-file . 1) (with-input-from-port . 1) (call-with-output-file . 1)
    (with-output-to-file . 1) (with-output-to-port . 1) (call-with-values . 1) (do . 2) (syntax-case . 2)
    (dynamic-wind . 3) (let . ,%let-count) (match-let . ,%let-count) (receive . 2) (test-group . 1)
    (test-group-with-cleanup . 1) (match . 1) (match-let* . 1) (match-letrec . 1) (match-lambda . 0)
    (match-lambda* . 0) (opt-lambda . 1) (opt*-lambda . 1) (let-optionals . 2) (let-optionals* . 2)
    (check-case . 1) (lambda-checked . 1) (fluid-let . 1) (with-input-from-string . 1) (with-output-to-string . 0)
    (call-with-string-output-port . 0) (call-with-bytevector-output-port . 0) (call-with-current-continuation . 0)
    (with-exception-handler . 1) (critical-section . 0) (with-interrupts-disabled . 0) (pariah . 0)
    (with-profile-tracker . 0) (with-cost-center . 1) (with-source-path . 2)
    (call-with-immediate-continuation-mark . 1) (with-continuation-mark . 2) (record-case . 1) (rec . 1)
    (top-level-program . 1) (fluid-let-syntax . 1) (with-implicit . 1) (module . 1) (with-mutex . 1)
    (extend-syntax . 1) (with . 1) (trace-case-lambda . 1) (trace-define . 1) (trace-define-syntax . 1)
    (trace-do . 2) (trace-lambda . 2) (trace-let . 2) (use-plugin . 1) (plugin . 1) (config . 0)
    (call-as-owner . 1) (call-with-cancellation-masked . 0) (options:with . 1) (buffers:with-buffer . 1)
    (buffers:call-with-buffer . 1) (undo:with-edit-group . 1) (undo:call-with-edit-group . 1)
    (views:with-view . 1) (views:call-with-view . 1) (minibuffer:call-with-setup . 1)))
(tables:set! indentation:indenters mode indenter)
(advice-add! module-loaded %note-module-loaded)
(advice-add! batch-ended %update-names)
