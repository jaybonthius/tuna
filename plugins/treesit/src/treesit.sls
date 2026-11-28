#!tuna
(import (syntax-highlighting) (buffers) (document) (jobs) (languages) (modes) (views) (ask) (treesit highlight) (hooks) (options)
        (tables))

(define %self (current-owner))

(options:define-option excluded-captures
  '(variable variable.member function.call function.method.call constructor module operator
    punctuation.bracket punctuation.delimiter)
  (lambda (v) (and (list? v) (for-all symbol? v)))
  "Capture names drawn plain, each naming exactly one capture. Read in each buffer."
  (lambda (v) (syntax-highlighting:update!)))

(options:define-option query-folders '("~/.config/tuna/queries/")
  (lambda (v) (and (list? v) (for-all string? v)))
  "Folders searched first for a grammar's query files, before those of the loaded plugins and nvim-treesitter's."
  (lambda (v) (syntax-highlighting:update!)))

(module %internals
  (grammars-folder nvim-treesitter-queries plugin-query-folders stamped expanded tell-once! tell-once-for! problem-text)

  (define (grammars-folder)
    (string-append (or (getenv "HOME") "") "/.local/share/tuna/grammars"))

  ;; A plugin's own files sit in its folder beside its module, where Chez
  ;; finds the module's source.
  (define (plugin-folder module)
    (let-values ([(source object found?)
                  (default-library-search-handler 'treesit module (library-directories) (library-extensions))])
      (and source (string-append (path-parent source) "/" (symbol->string (car (last-pair module)))))))

  (define nvim-treesitter-queries
    (string-append (plugin-folder '(treesit)) "/nvim-treesitter/runtime/queries"))

  ;; As Neovim searches every runtime-path entry's queries/, every loaded
  ;; module's folder is searched, in load order, so a language plugin
  ;; ships query files without importing treesit, a language that borrows
  ;; a grammar gets its lender's, and a configuration that changes a fact
  ;; leaves them in use. A module's folder does not move, so it is looked
  ;; up once; whether it holds queries is asked each time.
  (define module-queries (make-hashtable equal-hash equal?))

  (define (plugin-query-folders)
    (filter (lambda (queries) (and queries (file-directory? queries)))
            (map (lambda (module)
                   (unless (hashtable-contains? module-queries module)
                     (hashtable-set! module-queries module
                       (let ([folder (plugin-folder module)]) (and folder (string-append folder "/queries")))))
                   (hashtable-ref module-queries module #f))
                 (loaded-modules))))

  ;; A job compiles its query files again only when what it is sent
  ;; changes, so a file edited in place must change the input. A file gone
  ;; since it was found has no time; the job reports it when reading it.
  (define (stamped file)
    (cons file
          (guard (c [(i/o-error? c) #f])
            (let ([t (file-modification-time file)])
              (cons (time-second t) (time-nanosecond t))))))

  (define (expanded folder)
    (if (and (fx>= (string-length folder) 2) (string=? (substring folder 0 2) "~/"))
        (string-append (or (getenv "HOME") "") (substring folder 1 (string-length folder)))
        folder))

  (define (shown path)
    (let ([home (or (getenv "HOME") "")])
      (if (and (fx> (string-length home) 0)
               (fx> (string-length path) (string-length home))
               (string=? (substring path 0 (string-length home)) home)
               (char=? (string-ref path (string-length home)) #\/))
          (string-append "~" (substring path (string-length home) (string-length path)))
          path)))

  ;; A message told while a batch ends would show only when another
  ;; batch comes, so it goes in a task of its own.
  (define (tell! text)
    (call-as-owner %self (lambda () (spawn-task (lambda (restore) (ask:message text))))))

  (define told (make-hashtable equal-hash equal?))

  (define (tell-once! key text)
    (unless (hashtable-contains? told key)
      (hashtable-set! told key #t)
      (tell! text)))

  (define told-buffers (make-weak-eq-hashtable))

  (define (tell-once-for! buffer text)
    (unless (eq-hashtable-contains? told-buffers buffer)
      (eq-hashtable-set! told-buffers buffer #t)
      (tell! text)))

  (define (capitalized s)
    (if (fx= (string-length s) 0)
        s
        (string-append (string (char-upcase (string-ref s 0))) (substring s 1 (string-length s)))))

  (define (problem-text grammar-name problem)
    (case (car problem)
      [(grammar-error)
       (format "Loading the tree-sitter grammar for ~a failed: ~a" grammar-name (caddr problem))]
      [(query-error)
       (let-values ([(file row column message) (apply values (cdr problem))])
         (format "~a highlights query: ~a at row ~a, column ~a (~a)" (capitalized grammar-name) message row column
           (shown file)))])))

(import %internals)

(define (grammar-file grammar)
  (unless (languages:grammar? grammar)
    (assertion-violation 'treesit:grammar-file "not a grammar" grammar))
  (or (languages:grammar-prebuilt grammar)
      (format "~a/libtree-sitter-~a-~a.so" (grammars-folder) (languages:grammar-name grammar)
        (substring (languages:grammar-commit grammar) 0 12))))

(define (%grammar-of language) (and language (languages:grammar-of language)))

;; Whether a language has a grammar entry at all: an entry of the wrong
;; shape still chooses this highlighter, whose input reports it once, so
;; a scroll or a choice does not report it again.
(define (%grammar-entry? language) (and language (tables:ref languages:grammar language #f) #t))

(jobs:define-worker (%highlighter input emit receive)
  (import (syntax-highlighting job) (treesit highlight))
  (serve input emit receive (make-highlight)))

;; views gives the clients' ranges in no particular order; sorted, the
;; same ranges make an equal input, which is not sent again.
(define (%drawn-ranges buffer)
  (list-sort (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cdr a) (cdr b)))))
    (apply append (map views:drawn-ranges (views:showing buffer)))))

(define (%text-bytes buffer)
  (let ([doc (buffers:document buffer)])
    (document:offset doc (document:length doc) (document:unit bytes))))

(define (%highlight-input buffer problems)
  (let* ([language (languages:of (modes:major-mode buffer))]
         [grammar (%grammar-of language)])
    ;; A job's problems outlive its buffer's language, as when the mode's
    ;; plugin unloads, until the job stops at the end of the batch. They
    ;; are the grammar's and its queries', which languages may share.
    (when (and grammar problems)
      (for-each
        (lambda (problem)
          (tell-once! (if (eq? (car problem) 'grammar-error) (list 'grammar (cadr problem)) problem)
                      (problem-text (languages:grammar-name grammar) problem)))
        problems))
    (cond
      [(not grammar) #f]
      [(not (file-exists? (grammar-file grammar)))
       (when (languages:grammar-prebuilt grammar)
         (tell-once! (list 'missing (grammar-file grammar))
                     (format "No tree-sitter grammar for ~a at ~a" (languages:grammar-name grammar) (grammar-file grammar))))
       #f]
      ;; tree-sitter counts bytes in 32 bits.
      [(> (%text-bytes buffer) #xFFFFFFFF)
       (tell-once-for! buffer
         (format "Tree-sitter cannot parse ~a: its text is more than 4 GiB" (buffers:name buffer)))
       #f]
      [else
       (list (grammar-file grammar) (languages:grammar-name grammar)
             (map stamped
                  (query-files (append (map expanded (query-folders)) (plugin-query-folders)
                                       (list nvim-treesitter-queries))
                               (languages:grammar-name grammar) "highlights"))
             (excluded-captures)
             (%drawn-ranges buffer))])))

(define highlighter
  (syntax-highlighting:make-highlighter %highlighter (list syntax-highlighting:faces) %highlight-input))

(define (%input-changed! buffer)
  (let ([language (languages:of (modes:major-mode buffer))])
    (when (%grammar-entry? language)
      (syntax-highlighting:input-changed! buffer))))

(define (%choose-highlighter mode language)
  (and (%grammar-entry? language) highlighter))

;; A scroll needs only the input read again; update! would also start
;; again a buffer whose highlighter raised, and report it at every scroll.
(define (%drawn-ranges-changed view buffer) (%input-changed! buffer))

;; A plugin that loads or reloads may declare a language, or change its
;; query files, under buffers already open.
(define (%module-loaded loaded name)
  (loaded name)
  (for-each %input-changed! (buffers:all)))

(hooks:add! syntax-highlighting:choosers %choose-highlighter)
(hooks:add! views:drawn-ranges-changed %drawn-ranges-changed)
(advice-add! module-loaded %module-loaded)
