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
  "Folders searched first for a language's query files, before the plugin's own and nvim-treesitter's."
  (lambda (v) (syntax-highlighting:update!)))

(module %internals
  (check-name grammars-folder shipped-query-folders expanded tell-once! tell-once-for! problem-text)

  (define (check-name who name)
    (unless (and (string? name) (fx> (string-length name) 0)
                 (for-all (lambda (c) (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\_)))
                          (string->list name)))
      (assertion-violation who "not a grammar's name: letters, digits and _" name)))

  (define (grammars-folder)
    (string-append (or (getenv "HOME") "") "/.local/share/tuna/grammars"))

  ;; The plugin's own files sit in its folder beside this module, where
  ;; Chez finds the module's source.
  (define plugin-folder
    (let-values ([(source object found?)
                  ((library-search-handler) 'treesit '(treesit) (library-directories) (library-extensions))])
      (string-append (path-parent source) "/treesit")))

  (define shipped-query-folders
    (list (string-append plugin-folder "/queries")
          (string-append plugin-folder "/nvim-treesitter/runtime/queries")))

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
             (query-files (append (map expanded (query-folders)) shipped-query-folders)
                          (grammar-name grammar) "highlights")
             (excluded-captures)
             (%drawn-ranges buffer))])))

(define highlighter
  (syntax-highlighting:make-highlighter %highlighter (list syntax-highlighting:faces) %highlight-input))

;; A scroll needs only the input read again; update! would also start
;; again a buffer whose highlighter raised, and report it at every scroll.
(define (%drawn-ranges-changed view buffer)
  (let ([language (modes:language (modes:major-mode buffer))])
    (when (and language (table-ref grammars language #f))
      (syntax-highlighting:input-changed! buffer))))

(table-set! grammars "python"
  (make-grammar "python" "https://github.com/tree-sitter/tree-sitter-python"
                "293fdc02038ee2bf0e2e206711b69c90ac0d413f"))
(table-set! syntax-highlighting:highlighters "python" highlighter)
(add-hook! views:drawn-ranges-changed %drawn-ranges-changed)
