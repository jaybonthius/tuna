#!tuna
(import (languages) (treesit) (syntax-highlighting) (buffers) (modes) (commands) (ask) (runs) (processes) (hooks)
        (options) (tables))

(define %self (current-owner))

(define-enumeration missing (ask always never) %missings)

(options:define-option when-missing (missing ask) (lambda (v) (and (symbol? v) (enum-set-member? v (enum-set-universe (%missings)))))
  "What a buffer whose grammar built from source has no file does: ask whether to install it, always install it, or never.")

(module %internals (handled? handle! grammars-folder other-files scratch-folder c-compiler cxx-compiler build-script
                    builds)

  ;; By the grammar's file, its name and commit, so a new pin asks again.
  (define handled (make-hashtable string-hash string=?))

  (define (handled? grammar) (hashtable-contains? handled (treesit:grammar-file grammar)))

  (define (handle! grammar) (hashtable-set! handled (treesit:grammar-file grammar) #t))

  (define (home-path path) (string-append (or (getenv "HOME") "") path))

  (define (grammars-folder grammar) (path-parent (treesit:grammar-file grammar)))

  (define (other-files grammar)
    (let ([folder (grammars-folder grammar)] [file (treesit:grammar-file grammar)]
          [prefix (string-append "libtree-sitter-" (languages:grammar-name grammar) "-")])
      (if (file-directory? folder)
          (filter (lambda (path) (not (string=? path file)))
                  (map (lambda (name) (string-append folder "/" name))
                       (filter (lambda (name)
                                 (and (fx= (string-length name) (fx+ (string-length prefix) 15))
                                      (string=? prefix (substring name 0 (string-length prefix)))
                                      (string=? ".so" (substring name (fx- (string-length name) 3) (string-length name)))))
                               (directory-list folder))))
          '())))

  (define (scratch-folder grammar)
    (home-path (string-append "/.cache/tuna/grammars/" (languages:grammar-name grammar))))

  (define (c-compiler) (exists processes:program-path '("cc" "gcc" "c99")))

  (define (cxx-compiler) (exists processes:program-path '("c++" "g++")))

  ;; Positional parameters carry every path and name, so nothing in them
  ;; is read by the shell. set -x writes each command into the run, so its
  ;; buffer shows what was run and what it said. A source folder is only
  ;; fetched from, so the user's own checkout is left as it was.
  (define build-script
    "set -ex
rm -rf \"$3\"
mkdir -p \"$3\"
cd \"$3\"
git init -q
git fetch -q --depth 1 \"$1\" \"$2\"
git checkout -q FETCH_HEAD
cd \"$4\"
test -f src/parser.c
if test -f src/scanner.cc; then test -n \"$6\"; fi
\"$5\" -O2 -fPIC -Isrc -c src/parser.c -o parser.o
linker=\"$5\"
objects=parser.o
if test -f src/scanner.cc; then
  \"$6\" -O2 -fPIC -Isrc -c src/scanner.cc -o scanner.o
  linker=\"$6\"
  objects=\"parser.o scanner.o\"
elif test -f src/scanner.c; then
  \"$5\" -O2 -fPIC -Isrc -c src/scanner.c -o scanner.o
  objects=\"parser.o scanner.o\"
fi
mkdir -p \"$(dirname \"$7\")\"
\"$linker\" -shared -o \"$7\" $objects
cd /
rm -rf \"$3\"")

  (define builds (make-weak-eq-hashtable)))

(import %internals)

(define (%run-name grammar) (string-append "*treesit-install " (languages:grammar-name grammar) "*"))

(define (%temporary grammar) (string-append (treesit:grammar-file grammar) ".part"))

(define (%tell-cannot grammar what)
  (ask:message (format "Installing the tree-sitter grammar for ~a needs ~a" (languages:grammar-name grammar) what)))

(define (%build! grammar)
  (handle! grammar)
  (let ([git (processes:program-path "git")] [cc (c-compiler)])
    (cond
      [(not git) (%tell-cannot grammar "git, which is not on the PATH")]
      [(not cc) (%tell-cannot grammar "a C compiler: cc, gcc or c99")]
      [else
       (ask:message (format "Installing the tree-sitter grammar for ~a…" (languages:grammar-name grammar)))
       (let ([b (call-as-owner %self
                  (lambda ()
                    (runs:start (%run-name grammar)
                      (list "/bin/sh" "-c" build-script "treesit-install" (languages:grammar-url grammar)
                            (languages:grammar-commit grammar) (scratch-folder grammar)
                            (languages:grammar-location grammar) cc (or (cxx-compiler) "") (%temporary grammar)))))])
         (eq-hashtable-set! builds b grammar))])))

(define (%grammar-buffers grammar)
  (let ([file (treesit:grammar-file grammar)])
    (filter (lambda (b)
              (let* ([language (languages:of (modes:major-mode b))]
                     [g (and language (languages:grammar-of language))])
                (and g (string=? file (treesit:grammar-file g)))))
            (buffers:all))))

;; git init leaves HEAD naming a branch with no commit; the checkout of
;; the fetched commit detaches it.
(define (%checked-out? grammar)
  (let ([head (string-append (scratch-folder grammar) "/.git/HEAD")])
    (and (file-exists? head)
         (let ([text (call-with-input-file head get-string-all)])
           (not (and (string? text) (fx>= (string-length text) 4) (string=? "ref:" (substring text 0 4))))))))

(define (%failure-text grammar)
  (let* ([checkout (string-append (scratch-folder grammar) "/" (languages:grammar-location grammar))]
         [name (languages:grammar-name grammar)])
    (cond
      [(and (%checked-out? grammar) (not (file-exists? (string-append checkout "/src/parser.c"))))
       (format "The tree-sitter grammar for ~a must be generated, which needs the tree-sitter program; build it yourself and name its file with a (file …) grammar" name)]
      [(and (file-exists? (string-append checkout "/src/scanner.cc")) (not (cxx-compiler)))
       (format "Installing the tree-sitter grammar for ~a needs a C++ compiler: c++ or g++" name)]
      [else (format "Installing the tree-sitter grammar for ~a failed; see ~a" name (%run-name grammar))])))

(define (%build-ended buffer end)
  (let ([grammar (eq-hashtable-ref builds buffer #f)])
    (when grammar
      (eq-hashtable-delete! builds buffer)
      (if (eqv? end 0)
          (begin
            (rename-file (%temporary grammar) (treesit:grammar-file grammar))
            (for-each delete-file (other-files grammar))
            (ask:message (format "Installed the tree-sitter grammar for ~a" (languages:grammar-name grammar)))
            (for-each syntax-highlighting:update! (%grammar-buffers grammar)))
          (ask:message (%failure-text grammar))))))

(define (%missing-grammar buffer)
  (let* ([language (languages:of (modes:major-mode buffer))]
         [grammar (and language (languages:grammar-of language))])
    (and grammar
         (languages:grammar-url grammar)
         (not (file-exists? (treesit:grammar-file grammar)))
         (not (handled? grammar))
         grammar)))

(define (%question grammar)
  (format "~a the tree-sitter grammar for ~a from ~a? " (if (null? (other-files grammar)) "Install" "Update")
    (languages:grammar-name grammar) (languages:grammar-url grammar)))

;; The question waits in a task of its own, so the visit that needed the
;; grammar ends and its buffer shows first.
(define (%mode-changed buffer)
  (let ([grammar (%missing-grammar buffer)])
    (when grammar
      (let ([choice (buffers:with-buffer buffer (when-missing))])
        (unless (eq? choice (missing never))
          (handle! grammar)
          (call-as-owner %self
            (lambda ()
              (spawn-task
                (lambda (restore)
                  (when (or (eq? choice (missing always)) (ask:y-or-n? (%question grammar)))
                    (%build! grammar)))))))))))

(define (%source-languages)
  (filter (lambda (language)
            (let ([g (languages:grammar-of language)])
              (and g (languages:grammar-url g))))
          (map car (tables:entries languages:grammar))))

(define (%read-language)
  (ask:choice "Install the tree-sitter grammar of the language: " (map (lambda (l) (cons l l)) (%source-languages))))

(commands:define-command (grammar [language (%read-language)])
  "Installs the tree-sitter grammar of LANGUAGE at its commit, whether or not it is installed; asks the language among those whose grammar is built from source."
  (let ([g (and (string? language) (languages:grammar-of language))])
    (unless (and g (languages:grammar-url g))
      (assertion-violation 'treesit-install:grammar "no grammar built from source for the language" language))
    (%build! g)))

(hooks:add! modes:major-mode-changed %mode-changed)
(hooks:add! runs:ended %build-ended)
