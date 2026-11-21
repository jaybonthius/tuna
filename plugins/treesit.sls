#!tuna
(import (syntax-highlighting) (buffers) (document) (jobs) (modes) (views) (ask) (treesit highlight))

(define-record-type (grammar %make-grammar grammar?)
  (sealed #t)
  (fields name source commit file))

(define-table grammars
  "Maps a language, as modes:language names it, to its grammar.")

(define-option excluded-captures
  '(variable variable.member function.call function.method.call constructor module operator
    punctuation.bracket punctuation.delimiter)
  (lambda (v) (and (list? v) (for-all symbol? v)))
  "Capture names drawn plain, each naming exactly one capture. Read in each buffer."
  (lambda (v) (syntax-highlighting:update!)))

(define-option query-folders '("~/.config/tuna/queries/")
  (lambda (v) (and (list? v) (for-all string? v)))
  "Folders searched first for a language's query files, before those of the plugins that declare the language and nvim-treesitter's."
  (lambda (v) (syntax-highlighting:update!)))

(module %internals
  (check-name grammars-folder nvim-treesitter-queries language-query-folders stamped expanded tell-once!
   tell-once-for! problem-text)

  (define (check-name who name)
    (unless (and (string? name) (fx> (string-length name) 0)
                 (for-all (lambda (c) (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\_)))
                          (string->list name)))
      (assertion-violation who "not a grammar's name: letters, digits and _" name)))

  (define (grammars-folder)
    (string-append (or (getenv "HOME") "") "/.local/share/tuna/grammars"))

  ;; A plugin's own files sit in its folder beside its module, where Chez
  ;; finds the module's source.
  (define (plugin-folder module)
    (let-values ([(source object found?)
                  ((library-search-handler) 'treesit module (library-directories) (library-extensions))])
      (and source (string-append (path-parent source) "/" (symbol->string (car (last-pair module)))))))

  (define nvim-treesitter-queries
    (string-append (plugin-folder '(treesit)) "/nvim-treesitter/runtime/queries"))

  ;; The plugin that declares a language owns its mode's entry in
  ;; modes:languages, so a language plugin ships its query files without
  ;; importing treesit. The configuration and the REPL can own entries
  ;; too; they are not modules and have no folder.
  (define (language-query-folders language)
    (fold-left
      (lambda (folders entry)
        (let* ([owner (and (equal? (cdr entry) language) (table-owner modes:languages (car entry)))]
               [folder (and owner (member owner (loaded-modules)) (plugin-folder owner))]
               [queries (and folder (string-append folder "/queries"))])
          (if (and queries (not (member queries folders))) (append folders (list queries)) folders)))
      '() (table-entries modes:languages)))

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
    (as-module (this-module) (post! (lambda () (ask:message text)))))

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

  (define (problem-text language problem)
    (case (car problem)
      [(grammar-error)
       (format "Loading the tree-sitter grammar for ~a failed: ~a" language (caddr problem))]
      [(query-error)
       (let-values ([(file row column message) (apply values (cdr problem))])
         (format "~a highlights query: ~a at row ~a, column ~a (~a)" (capitalized language) message row column
           (shown file)))])))

(import %internals)

(define (make-grammar name source commit)
  (check-name 'treesit:make-grammar name)
  (unless (string? source)
    (assertion-violation 'treesit:make-grammar "not a URL or folder" source))
  (unless (and (string? commit) (fx= (string-length commit) 40)
               (for-all (lambda (c) (or (char<=? #\0 c #\9) (char<=? #\a c #\f) (char<=? #\A c #\F)))
                        (string->list commit)))
    (assertion-violation 'treesit:make-grammar "not a full commit: 40 hexadecimal digits" commit))
  (%make-grammar name source commit
    (format "~a/libtree-sitter-~a-~a.so" (grammars-folder) name (substring commit 0 12))))

(define (make-prebuilt-grammar name file)
  (check-name 'treesit:make-prebuilt-grammar name)
  (unless (string? file)
    (assertion-violation 'treesit:make-prebuilt-grammar "not a file name" file))
  (%make-grammar name #f #f file))

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
  (let* ([language (modes:language (modes:major-mode buffer))]
         [grammar (and language (table-ref grammars language #f))])
    (when (and grammar (not (grammar? grammar)))
      (assertion-violation 'treesit:grammars "not a grammar" grammar))
    (when problems
      (for-each
        (lambda (problem)
          (tell-once! (if (eq? (car problem) 'grammar-error) (list 'grammar (cadr problem)) problem)
                      (problem-text language problem)))
        problems))
    (cond
      [(not grammar) #f]
      [(not (file-exists? (grammar-file grammar)))
       (unless (grammar-source grammar)
         (tell-once! (list 'missing (grammar-file grammar))
                     (format "No tree-sitter grammar for ~a at ~a" language (grammar-file grammar))))
       #f]
      ;; tree-sitter counts bytes in 32 bits.
      [(> (%text-bytes buffer) #xFFFFFFFF)
       (tell-once-for! buffer
         (format "Tree-sitter cannot parse ~a: its text is more than 4 GiB" (buffers:name buffer)))
       #f]
      [else
       (list (grammar-file grammar) (grammar-name grammar)
             (map stamped
                  (query-files (append (map expanded (query-folders)) (language-query-folders language)
                                       (list nvim-treesitter-queries))
                               (grammar-name grammar) "highlights"))
             (excluded-captures)
             (%drawn-ranges buffer))])))

(define highlighter
  (syntax-highlighting:make-highlighter %highlighter (list syntax-highlighting:faces) %highlight-input))

(define (%input-changed! buffer)
  (let ([language (modes:language (modes:major-mode buffer))])
    (when (and language (table-ref grammars language #f))
      (syntax-highlighting:input-changed! buffer))))

;; A scroll needs only the input read again; update! would also start
;; again a buffer whose highlighter raised, and report it at every scroll.
(define (%drawn-ranges-changed view buffer) (%input-changed! buffer))

;; A plugin that loads or reloads may declare a language, or change its
;; query files, under buffers already open.
(define (%module-loaded loaded name)
  (loaded name)
  (for-each %input-changed! (buffers:all)))

(table-set! grammars "python"
  (make-grammar "python" "https://github.com/tree-sitter/tree-sitter-python"
                "293fdc02038ee2bf0e2e206711b69c90ac0d413f"))
(table-set! syntax-highlighting:highlighters "python" highlighter)
(add-hook! views:drawn-ranges-changed %drawn-ranges-changed)
(advice-add! module-loaded %module-loaded)
