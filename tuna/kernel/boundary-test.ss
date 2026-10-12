;;; Mechanical checks of the kernel and library boundaries (ADR 12, "Kernel
;;; contract").
;;;
;;; tuna/kernel/ may hold only Gerbil source and the baseline. Kernel source
;;; may import only :gerbil, :std, and kernel modules, may include only
;;; checked kernel files, and must not use the nouns ADR 12 forbids. Known
;;; noun hits are listed in boundary-baseline.sexp; the check fails on any
;;; hit beyond that list and on any entry larger than what remains, so the
;;; list can only shrink as the kernel cleanup
;;; (agents/plans/kernel-cleanup.md) lands.
;;;
;;; tuna/lib/ may hold only Gerbil source. Library source may import only
;;; :gerbil, :std, the kernel facade :tuna/kernel, and library modules, and
;;; may include only checked library files. Libraries may use the nouns.
(import (only-in :gerbil/runtime/hash HashTable)
        :std/misc/ports
        :std/source
        :std/test)
(export boundary-test)

;; ADR 12, "Kernel contract": the nouns the kernel must never know about.
;; Source text (code and comments) is split into lowercase words at every
;; non-alphanumeric character, at CamelCase boundaries, and between letters
;; and digits; each term below matches as that sequence of words, even
;; across a line break, so "define-command" also matches
;; context-define-command! and "define command". Amend these lists
;; together with the ADR.
(def forbidden-words
  '("key" "keys" "keyed" "keying" "keymap" "keymaps" "keyboard"
    "keydown" "keyup" "keypress" "keystroke" "keystrokes"
    "mouse"
    "browser" "browsers"
    "http" "https" "html" "datastar" "sse" "dom"
    "client" "clients"
    "text" "texts"
    "char" "chars" "character" "characters"
    "position" "positions"
    "range" "ranges"
    "span" "spans"
    "buffer" "buffers"
    "view" "views"
    "window" "windows"
    "frame" "frames"
    "screen" "screens"
    "render" "renders" "rendered" "renderer" "rendering" "renderable"
    "setting" "settings"
    "file" "files"
    "save" "saves" "saved" "saving" "autosave"
    "session" "sessions"
    "timer" "timers"
    "profile" "profiles" "profiler" "profiling"
    "latency"
    "measure" "measures" "measured" "measuring" "measurement" "measurements"
    "demo" "demos"))

;; ADR 12: the kernel has no command registry; it announces tasks, not
;; commands, starting and finishing. The bare word "command" stays allowed
;; for generic phrases such as "command loop".
(def forbidden-registry-names
  '("defcommand" "define-command" "command-ref" "command-entry" "command-registry"
    "kernel-commands"))

;; Kernel test support, excluded from the checks. It moves out of the
;; kernel in kernel-cleanup step 7; each name must exist.
(def kernel-test-support-files '("tuna/kernel/test-fixtures.ss"))

;; The source location may be relative to the directory gerbil test runs
;; in; expanding it at load time resolves it against that same directory.
(def kernel-directory (path-expand (this-source-directory)))   ; .../tuna/kernel/
(def tuna-directory
  (path-directory (path-strip-trailing-directory-separator kernel-directory)))
(def root-directory
  (path-directory (path-strip-trailing-directory-separator tuna-directory)))
(def baseline-name "tuna/kernel/boundary-baseline.sexp")

(def (source-path (name : :string)) => :string
  (path-expand name root-directory))

;;; Checked layers

;; A layer whose imports are checked (ADR 12, "Kernel contract"): the
;; directory holding its modules (:tuna/<dir>/x), its facade file if any
;; (:tuna/<dir>), the other files the directory may hold, the test support
;; excluded from the checks, and the modules it may import besides
;; :gerbil/..., :std/..., and its own checked modules.
(defstruct layer ((name         : :string)
                  (directory    : :string)
                  (facade       :? :string)
                  (extra-files  : :list)
                  (test-support : :list)
                  (also-imports : :list))
  final: #t)

;; The kernel: its facade tuna/kernel.ss and tuna/kernel/.
(def kernel-layer
  (make-layer "kernel" "tuna/kernel" "tuna/kernel.ss" [baseline-name] kernel-test-support-files []))

;; Shared libraries, built only on the public kernel API: no kernel
;; module other than the facade, no contract, no plugin, no prelude.
(def library-layer
  (make-layer "library" "tuna/lib" #f [] [] [":tuna/kernel"]))

(def (layer-allowed (l : layer)) => :string
  (string-append ":gerbil/..., :std/..., "
                 (apply string-append (map (cut string-append <> ", ") (layer-also-imports l)))
                 "and checked " (layer-name l) " modules (ADR 12)"))

;;; The layer trees

;; Every non-directory entry under DIRECTORY, hidden ones included, as
;; (name . type) with NAME relative to the repository root.
(def (tree-entries (directory : :string)) => :list
  (let walk ((dir directory))
    (apply append
           (map (lambda ((name : :string))
                  (let* ((relative (string-append dir "/" name))
                         (type (file-info-type (file-info (source-path relative) #f))))
                    (if (eq? type 'directory)
                      (walk relative)
                      [(cons relative type)])))
                (list-sort string<?
                           (directory-files (list path: (source-path dir)
                                                  ignore-hidden: 'dot-and-dot-dot)))))))

;; Entries other than regular .ss files and the layer's extra files, so no
;; other kind of source can hide in the layer, and test-support exclusions
;; naming no file.
(def (tree-problems (l : layer)) => :list
  (let* ((entries (tree-entries (layer-directory l)))
         (allowed (string-append (layer-directory l) "/ may hold only .ss files"
                                 (apply string-append
                                        (map (cut string-append " and " <>) (layer-extra-files l))))))
    (append
     (filter-map
      (lambda ((entry : :pair))
        (let ((name (car entry))
              (type (cdr entry)))
          (cond
           ((not (eq? type 'regular))
            (string-append name ": is a " (symbol->string type) "; " allowed))
           ((or (string-suffix? ".ss" name) (member name (layer-extra-files l))) #f)
           (else (string-append name ": " allowed)))))
      entries)
     (filter-map
      (lambda ((name : :string))
        (and (not (assoc name entries))
             (string-append name ": listed as test support but does not exist;"
                            " remove it from tuna/kernel/boundary-test.ss")))
      (layer-test-support l)))))

;; The checked files of L, relative to the repository root: its facade and
;; every non-test .ss file under its directory.
(def (layer-source-names (l : layer)) => :list
  (let (files (filter (lambda ((name : :string))
                        (and (string-suffix? ".ss" name)
                             (not (string-suffix? "-test.ss" name))
                             (not (member name (layer-test-support l)))))
                      (map car (filter (lambda ((entry : :pair)) (eq? (cdr entry) 'regular))
                                       (tree-entries (layer-directory l))))))
    (if (layer-facade l) (cons (layer-facade l) files) files)))

(def (kernel-source-names) => :list
  (layer-source-names kernel-layer))

;; Plugin names, from the module files in tuna/plugins/.
(def (plugin-names) => :list
  (list-sort string<?
             (map path-strip-extension
                  (filter (lambda ((file : :string))
                            (and (string-suffix? ".ss" file)
                                 (not (string-suffix? "-test.ss" file))))
                          (directory-files (path-expand "plugins" tuna-directory))))))

;;; Imports and includes

(def (read-forms (path : :string)) => :list
  (call-with-input-file path
    (lambda (port)
      (let lp ((forms []))
        (let (form (read port))
          (if (eof-object? form)
            (reverse forms)
            (lp (cons form forms))))))))

;; The elements of FORM, ignoring an improper tail.
(def (elements (form : :t)) => :list
  (let lp ((rest form) (found []))
    (if (pair? rest)
      (lp (cdr rest) (cons (car rest) found))
      (reverse found))))

;; Module names in an import spec: symbols starting with ":" or ".", and
;; path strings. Identifiers inside only-in and the like are skipped.
(def (spec-module-names (spec : :t)) => :list
  (cond
   ((pair? spec) (append (spec-module-names (car spec)) (spec-module-names (cdr spec))))
   ((string? spec) [spec])
   ((symbol? spec)
    (let (name (symbol->string spec))
      (if (or (string-prefix? ":" name) (string-prefix? "." name)) [name] [])))
   (else [])))

;; Every module FORM names, at any depth, in a prelude:, an import form, or
;; an import: re-export.
(def (imported-module-names (form : :t)) => :list
  (cond
   ((not (pair? form)) [])
   ((memq (car form) '(import import:)) (spec-module-names (cdr form)))
   (else
    (let lp ((rest (elements form)) (found []))
      (match rest
        ([(? (cut eq? <> prelude:)) module . more]
         (lp more (append found (spec-module-names module))))
        ([x . more] (lp more (append found (imported-module-names x))))
        (_ found))))))

;; Every symbol in FORM, at any depth, quoted data and macro bodies
;; included, that is spelled like a module name: ":a/b", "./x", or "../x".
;; A macro can build an import from any of them.
(def (module-like-symbols (form : :t)) => :list
  (cond
   ((pair? form) (append (module-like-symbols (car form)) (module-like-symbols (cdr form))))
   ((vector? form) (module-like-symbols (vector->list form)))
   ((symbol? form)
    (let (name (symbol->string form))
      (if (or (and (string-prefix? ":" name) (string-index name #\/))
              (string-prefix? "./" name)
              (string-prefix? "../" name))
        [name]
        [])))
   (else [])))

(def (unique (items : :list)) => :list
  (reverse (foldl (lambda (item (found : :list)) (if (member item found) found (cons item found)))
                  [] items)))

;; Every path FORM includes, at any depth.
(def (included-paths (form : :t)) => :list
  (if (pair? form)
    (let (parts (elements form))
      (append (if (eq? (car form) 'include) (filter string? (cdr parts)) [])
              (apply append (map included-paths parts))))
    []))

(def (parent-segment? (name : :string)) => :boolean
  (and (member ".." (string-split name #\/)) #t))

;; The root-relative source file of NAME if it names a module of L (its
;; facade :tuna/<dir>, :tuna/<dir>/x, or ./x relative to FILE), or #f.
(def (layer-module-file (l : layer) (file : :string) (name : :string)) => (Maybe :string)
  (let ((facade (layer-facade l))
        (prefix (string-append ":" (layer-directory l) "/")))
    (cond
     ((and facade (equal? name (string-append ":" (path-strip-extension facade)))) facade)
     ((string-prefix? prefix name)
      (string-append (substring name 1 (string-length name)) ".ss"))
     ((string-prefix? "./" name)
      (let (path (path-expand (string-append (substring name 2 (string-length name)) ".ss")
                              (path-directory (source-path file))))
        (and (string-prefix? root-directory path)
             (substring path (string-length root-directory) (string-length path)))))
     (else #f))))

;; Whether NAME, imported by FILE of L, is :gerbil, :std, one of L's other
;; allowed modules, or a checked module of L; test files and test support
;; are not.
(def (allowed-import? (l : layer) (file : :string) (name : :string) (checked : :list)) => :boolean
  (cond
   ((parent-segment? name) #f)
   ((or (string-prefix? ":gerbil/" name) (string-prefix? ":std/" name)) #t)
   ((member name (layer-also-imports l)) #t)
   (else
    (let (target (layer-module-file l file name))
      (and target (member target checked) #t)))))

;; Whether TARGET, included by the file named FILE, is a checked file.
(def (allowed-include? (file : :string) (target : :string) (checked : :list)) => :boolean
  (and (not (parent-segment? target))
       (member (path-expand target (path-directory (source-path file)))
               (map source-path checked))
       #t))

;; The 1-based numbers of the lines of LINES that contain NEEDLE.
(def (lines-containing (lines : :list) (needle : :string)) => :list
  (let lp ((rest lines) (number 1) (found []))
    (match rest
      ([] (reverse found))
      ([line . more]
       (lp more (fx1+ number)
           (if (string-contains line needle) (cons number found) found))))))

(def (import-problems (l : layer)) => :list
  (let (checked (layer-source-names l))
    (apply append
           (map (lambda ((file : :string))
                  (let* ((path (source-path file))
                         (forms (read-forms path))
                         (where (lambda ((needle : :string))
                                  (string-append " (lines "
                                                 (number-list
                                                  (lines-containing (read-file-lines path) needle))
                                                 ")"))))
                    (append
                     (filter-map
                      (lambda ((name : :string))
                        (and (not (allowed-import? l file name checked))
                             (string-append file ": imports " name (where name)
                                            "; the " (layer-name l) " may import only "
                                            (layer-allowed l))))
                      (unique (append (imported-module-names forms)
                                      (module-like-symbols forms))))
                     (filter-map
                      (lambda ((target : :string))
                        (and (not (allowed-include? file target checked))
                             (string-append file ": includes " target (where target)
                                            "; the " (layer-name l)
                                            " may include only its checked files")))
                      (included-paths forms)))))
                checked))))

;;; Forbidden nouns

(def (word-char? (c : :char)) => :boolean
  (or (char-alphabetic? c) (char-numeric? c)))

(def (segment-cons (line : :string) (start : :fixnum) (end : :fixnum) (found : :list)) => :list
  (if (fx< start end)
    (cons (string-downcase (substring line start end)) found)
    found))

;; Whether a word starts at I inside a run of letters and digits: a
;; capital after a lowercase letter ("KeyEvent"), the last capital of an
;; acronym ("HTTPServer"), or a change between letters and digits
;; ("utf8Key", "key2").
(def (word-boundary? (line : :string) (i : :fixnum) (end : :fixnum)) => :boolean
  (let ((c (string-ref line i))
        (previous (string-ref line (fx1- i))))
    (or (and (char-upper-case? c)
             (or (char-lower-case? previous)
                 (and (char-upper-case? previous)
                      (fx< (fx1+ i) end)
                      (char-lower-case? (string-ref line (fx1+ i))))))
        (and (char-numeric? c) (char-alphabetic? previous))
        (and (char-alphabetic? c) (char-numeric? previous)))))

;; LINE's words, lowercased: runs of letters and digits, split again at
;; each word-boundary?.
(def (line-segments (line : :string)) => :list
  (let (end (string-length line))
    (let lp ((i 0) (start 0) (found []))
      (if (fx= i end)
        (reverse (segment-cons line start end found))
        (let (c (string-ref line i))
          (cond
           ((not (word-char? c))
            (lp (fx1+ i) (fx1+ i) (segment-cons line start i found)))
           ((and (fx> i start) (word-boundary? line i end))
            (lp (fx1+ i) i (segment-cons line start i found)))
           (else (lp (fx1+ i) start found))))))))

;; Every forbidden term's label, once: words, registry names, then plugin
;; names that are not already words.
(def (forbidden-labels) => :list
  (unique (append forbidden-words forbidden-registry-names (plugin-names))))

;; First word -> the terms starting with it, each (label . words).
(def (term-index (labels : :list)) => HashTable
  (let (index (make-hash-table))
    (for-each (lambda ((label : :string))
                (let (words (string-split label #\-))
                  (hash-update! index (car words) (cut cons (cons label words) <>) [])))
              labels)
    index))

;; FILE's words in order, each (word . line number).
(def (file-words (file : :string)) => :list
  (let lp ((lines (read-file-lines (source-path file))) (number 1) (found []))
    (if (pair? lines)
      (lp (cdr lines) (fx1+ number)
          (foldl (lambda ((word : :string) (found : :list)) (cons (cons word number) found))
                 found (line-segments (car lines))))
      (reverse found))))

;; Whether WORDS start the sequence of (word . line) TOKENS.
(def (phrase-at? (words : :list) (tokens : :list)) => :boolean
  (or (null? words)
      (and (pair? tokens)
           (equal? (car words) (caar tokens))
           (phrase-at? (cdr words) (cdr tokens)))))

;; One (file, term) hit count, with the numbers of the lines it occurs on.
(defstruct hits ((file  : :string)
                 (label : :string)
                 (count : :fixnum)
                 (lines : :list))
  final: #t)

;; FILE's hits of the terms in INDEX, by label. A hit is reported on the
;; line of its first word.
(def (file-hits (file : :string) (index : HashTable)) => :list
  (let (table (make-hash-table))            ; label -> (count . line numbers, newest first)
    (let scan ((tokens (file-words file)))
      (when (pair? tokens)
        (let (number (cdar tokens))
          (for-each (lambda ((term : :pair))
                      (when (phrase-at? (cdr term) tokens)
                        (hash-update! table (car term)
                                      (lambda ((seen : :pair))
                                        (cons (fx1+ (car seen))
                                              (if (and (pair? (cdr seen)) (eqv? (cadr seen) number))
                                                (cdr seen)
                                                (cons number (cdr seen)))))
                                      (cons 0 []))))
                    (hash-ref index (caar tokens) [])))
        (scan (cdr tokens))))
    (map (lambda ((label : :string))
           (let (seen (hash-ref table label))
             (make-hits file label (car seen) (reverse (cdr seen)))))
         (list-sort string<? (hash-keys table)))))

(def (number-list (numbers : :list)) => :string
  (string-join (map number->string numbers) ", "))

;; One baseline entry: a known hit count and why it is still there.
(defstruct baseline-entry ((file   : :string)
                           (label  : :string)
                           (count  : :fixnum)
                           (reason : :string))
  final: #t)

;; The kernel-cleanup plan steps that remove baseline entries.
(def baseline-steps '("step 6" "step 7" "step 8"))

(def (valid-reason? (reason : :string)) => :boolean
  (or (and (member reason baseline-steps) #t)
      (and (string-prefix? "permanent: " reason)
           (fx> (string-length reason) (string-length "permanent: ")))))

(def (read-baseline) => :list
  (map (lambda (form)
         (match form
           ([(? string? file) (? string? label) (? fixnum? count) (? string? reason)]
            (unless (fx> count 0)
              (error "Baseline count must be positive" baseline-name form))
            (unless (valid-reason? reason)
              (error "Baseline reason must be \"step N\" (N from 6 to 8) or \"permanent: <why>\""
                     baseline-name form))
            (make-baseline-entry file label count reason))
           (else (error "Malformed baseline entry; expected (file term count reason)"
                        baseline-name form))))
       (read-forms (source-path baseline-name))))

;; Hit limits from the baseline: (file . term) -> the sum of its entries'
;; counts. A (file, term) may have several entries when its hits go away in
;; different steps.
(def (baseline-limits (baseline : :list)) => HashTable
  (let (limits (make-hash-table))
    (for-each (lambda ((e : baseline-entry))
                (hash-update! limits (cons (baseline-entry-file e) (baseline-entry-label e))
                              (cut fx+ <> (baseline-entry-count e)) 0))
              baseline)
    limits))

(def (noun-problems) => :list
  (let* ((index (term-index (forbidden-labels)))
         (actual (apply append (map (cut file-hits <> index) (kernel-source-names))))
         (counts (let (table (make-hash-table))
                   (for-each (lambda ((h : hits))
                               (hash-put! table (cons (hits-file h) (hits-label h)) (hits-count h)))
                             actual)
                   table))
         (limits (baseline-limits (read-baseline))))
    (append
     (filter-map
      (lambda ((h : hits))
        (let (limit (hash-ref limits (cons (hits-file h) (hits-label h)) 0))
          (and (fx> (hits-count h) limit)
               (string-append (hits-file h) ": forbidden term \"" (hits-label h) "\" has "
                              (number->string (hits-count h)) " hits, baseline allows "
                              (number->string limit) " (lines "
                              (number-list (hits-lines h)) ")"))))
      actual)
     (filter-map
      (lambda ((key : :pair))
        (let ((limit (hash-ref limits key))
              (count (hash-ref counts key 0)))
          (and (fx> limit count)
               (string-append (car key) ": baseline allows " (number->string limit)
                              " hits of \"" (cdr key) "\" but only " (number->string count)
                              " remain; lower or remove its entries in " baseline-name))))
      (list-sort (lambda ((a : :pair) (b : :pair))
                   (string<? (string-append (car a) " " (cdr a))
                             (string-append (car b) " " (cdr b))))
                 (hash-keys limits))))))

;; Print each problem on its own line and return how many there are, so a
;; failing check reports a count rather than repeating the whole list.
(def (problem-count (problems : :list)) => :fixnum
  (for-each (lambda (problem) (displayln "  " problem)) problems)
  (length problems))

(def boundary-test
  (test-suite "kernel and library boundary (ADR 12)"
    (test-case "tuna/kernel/ holds only .ss files and the baseline"
      (check (problem-count (tree-problems kernel-layer)) => 0))
    (test-case "kernel imports only :gerbil, :std, and kernel modules"
      (check (problem-count (import-problems kernel-layer)) => 0))
    (test-case "kernel forbidden nouns do not exceed the baseline"
      (displayln "  kernel boundary: " (length (kernel-source-names)) " files checked; "
                 baseline-name " allows "
                 (foldl fx+ 0 (hash-values (baseline-limits (read-baseline))))
                 " known forbidden-noun hits")
      (check (problem-count (noun-problems)) => 0))
    (test-case "tuna/lib/ holds only .ss files"
      (check (problem-count (tree-problems library-layer)) => 0))
    (test-case "libraries import only :gerbil, :std, :tuna/kernel, and library modules"
      (displayln "  library boundary: " (length (layer-source-names library-layer)) " files checked")
      (check (problem-count (import-problems library-layer)) => 0))))
