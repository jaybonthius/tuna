;;; Mechanical checks of the kernel boundary (ADR 12, "Kernel contract").
;;;
;;; Kernel source may import only :gerbil, :std, and kernel modules, and must
;;; not use the nouns ADR 12 forbids. Known noun hits are listed in
;;; boundary-baseline.sexp; the check fails on any hit beyond that list and
;;; on any entry larger than what remains, so the list can only shrink as
;;; the kernel cleanup (agents/plans/kernel-cleanup.md) lands.
(import (only-in :gerbil/runtime/hash HashTable)
        :std/misc/ports
        :std/source
        :std/test)
(export boundary-test)

;; ADR 12, "Kernel contract": the nouns the kernel must never know about,
;; matched as whole words after splitting source text (code and comments)
;; on every non-alphanumeric character, ignoring case. Amend this list
;; together with the ADR.
(def forbidden-words
  '("key" "keys" "keymap" "keymaps" "keyboard"
    "mouse"
    "browser" "browsers"
    "http"
    "client" "clients"
    "text"
    "char" "chars" "character" "characters"
    "position" "positions"
    "range" "ranges"
    "span" "spans"
    "buffer" "buffers"
    "view" "views"
    "window" "windows"
    "frame" "frames"
    "screen" "screens"
    "render" "renders" "renderer" "rendering"
    "setting" "settings"
    "file" "files"
    "save" "saving" "autosave"
    "session" "sessions"
    "timer" "timers"
    "profile" "profiler" "profiling"
    "latency"
    "measure" "measurement"
    "demo"))

;; ADR 12: the kernel has no command registry. These are matched as whole
;; identifiers only; the bare word "command" stays allowed because the
;; kernel announces commands starting and finishing.
(def forbidden-identifiers
  '("defcommand" "define-command" "command-ref" "command-entry" "command-registry"))

;; Kernel test support, excluded from the checks. It moves out of the
;; kernel in kernel-cleanup step 7.
(def kernel-test-support-files '("test-fixtures.ss"))

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

;; The checked files, relative to the repository root: the facade and the
;; non-test modules of tuna/kernel/.
(def (kernel-source-names) => :list
  (cons "tuna/kernel.ss"
        (map (cut string-append "tuna/kernel/" <>)
             (list-sort string<?
                        (filter (lambda ((file : :string))
                                  (and (string-suffix? ".ss" file)
                                       (not (string-suffix? "-test.ss" file))
                                       (not (member file kernel-test-support-files))))
                                (directory-files kernel-directory))))))

;; Plugin names, from the module files in tuna/plugins/.
(def (plugin-names) => :list
  (list-sort string<?
             (map path-strip-extension
                  (filter (lambda ((file : :string))
                            (and (string-suffix? ".ss" file)
                                 (not (string-suffix? "-test.ss" file))))
                          (directory-files (path-expand "plugins" tuna-directory))))))

;;; Imports

(def (read-forms (path : :string)) => :list
  (call-with-input-file path
    (lambda (port)
      (let lp ((forms []))
        (let (form (read port))
          (if (eof-object? form)
            (reverse forms)
            (lp (cons form forms))))))))

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

;; Every module FORMS name in a prelude:, an import form, or an import:
;; re-export.
(def (imported-module-names (forms : :list)) => :list
  (let walk ((rest forms))
    (match rest
      ([(? (cut eq? <> prelude:)) module . more]
       (append (spec-module-names module) (walk more)))
      ([(? pair? form) . more]
       (append (if (memq (car form) '(import import:))
                 (spec-module-names (cdr form))
                 (walk form))
               (walk more)))
      ([_ . more] (walk more))
      (_ []))))

;; Whether NAME, imported by the file named FILE, is :gerbil, :std, or a
;; kernel module.
(def (allowed-import? (file : :string) (name : :string)) => :boolean
  (cond
   ((or (string-prefix? ":gerbil/" name) (string-prefix? ":std/" name)) #t)
   ((or (equal? name ":tuna/kernel") (string-prefix? ":tuna/kernel/" name)) #t)
   ((string-prefix? "./" name)
    (and (not (member ".." (string-split name #\/)))
         (string-prefix? kernel-directory
                         (path-expand (substring name 2 (string-length name))
                                      (path-directory (source-path file))))))
   (else #f)))

;; The 1-based numbers of the lines of LINES that contain NEEDLE.
(def (lines-containing (lines : :list) (needle : :string)) => :list
  (let lp ((rest lines) (number 1) (found []))
    (match rest
      ([] (reverse found))
      ([line . more]
       (lp more (fx1+ number)
           (if (string-contains line needle) (cons number found) found))))))

(def (import-problems) => :list
  (apply append
         (map (lambda ((file : :string))
                (let (path (source-path file))
                  (filter-map
                   (lambda ((name : :string))
                     (and (not (allowed-import? file name))
                          (string-append file ": imports " name " (lines "
                                         (number-list (lines-containing (read-file-lines path) name))
                                         "); the kernel may import only :gerbil/..., :std/..., and kernel modules (ADR 12)")))
                   (imported-module-names (read-forms path)))))
              (kernel-source-names))))

;;; Forbidden nouns

(def (word-char? (c : :char)) => :boolean
  (or (char-alphabetic? c) (char-numeric? c)))

(def identifier-delimiters (string->list " \t\r\n()[]{}\"';`,|"))

;; The maximal runs of LINE whose characters satisfy KEEP?, downcased.
(def (runs (line : :string) (keep? : :procedure)) => :list
  (let lp ((chars (string->list line)) (current []) (found []))
    (let (flush (lambda ()
                  (if (null? current)
                    found
                    (cons (string-downcase (list->string (reverse current))) found))))
      (match chars
        ([] (reverse (flush)))
        ([c . more]
         (if (keep? c)
           (lp more (cons c current) found)
           (lp more [] (flush))))))))

;; LINE's hyphenated words, each as its list of alphanumeric segments:
;; "(current-buffer x)" gives (("current" "buffer") ("x")).
(def (hyphenated-words (line : :string)) => :list
  (map (lambda ((run : :string))
         (filter (lambda ((s : :string)) (not (string-empty? s)))
                 (string-split run #\-)))
       (runs line (lambda (c) (or (word-char? c) (char=? c #\-))))))

(def (identifiers (line : :string)) => :list
  (runs line (lambda (c) (not (memv c identifier-delimiters)))))

;; How often the segment list PHRASE occurs consecutively in SEGMENTS.
(def (phrase-count (phrase : :list) (segments : :list)) => :fixnum
  (let lp ((rest segments) (count 0))
    (if (null? rest)
      count
      (lp (cdr rest)
          (if (let prefix? ((p phrase) (s rest))
                (or (null? p)
                    (and (pair? s) (equal? (car p) (car s)) (prefix? (cdr p) (cdr s)))))
            (fx1+ count)
            count)))))

;; A forbidden term: its label and a procedure counting its hits in a line.
(defstruct term ((label : :string)
                 (count : :procedure))      ; line -> fixnum
  final: #t)

(def (phrase-term (label : :string)) => term
  (let (phrase (string-split label #\-))
    (make-term label
               (lambda ((line : :string))
                 (foldl (lambda (word (sum : :fixnum)) (fx+ sum (phrase-count phrase word)))
                        0 (hyphenated-words line))))))

(def (identifier-term (label : :string)) => term
  (make-term label
             (lambda ((line : :string))
               (length (filter (cut equal? label <>) (identifiers line))))))

;; Words and plugin names match as segments of hyphenated words; plugin
;; names that are already forbidden words are not counted twice.
(def (forbidden-terms) => :list
  (append (map phrase-term forbidden-words)
          (map identifier-term forbidden-identifiers)
          (map phrase-term
               (filter (lambda (name) (not (member name forbidden-words)))
                       (plugin-names)))))

;; One (file, term) hit count, with the numbers of the lines it occurs on.
(defstruct hits ((file  : :string)
                 (label : :string)
                 (count : :fixnum)
                 (lines : :list))
  final: #t)

(def (file-hits (file : :string) (terms : :list)) => :list
  (let (lines (read-file-lines (source-path file)))
    (filter-map
     (lambda ((t : term))
       (let lp ((rest lines) (number 1) (total 0) (found []))
         (match rest
           ([]
            (and (fx> total 0) (make-hits file (term-label t) total (reverse found))))
           ([line . more]
            (let (n ((term-count t) line))
              (lp more (fx1+ number) (fx+ total n)
                  (if (fx> n 0) (cons number found) found)))))))
     terms)))

(def (number-list (numbers : :list)) => :string
  (string-join (map number->string numbers) ", "))

;; One baseline entry: a known hit count and why it is still there.
(defstruct baseline-entry ((file   : :string)
                           (label  : :string)
                           (count  : :fixnum)
                           (reason : :string))
  final: #t)

(def (valid-reason? (reason : :string)) => :boolean
  (or (string-prefix? "step " reason)
      (string-prefix? "permanent: " reason)
      (string-prefix? "unassigned: " reason)))

(def (read-baseline) => :list
  (map (lambda (form)
         (match form
           ([(? string? file) (? string? label) (? fixnum? count) (? string? reason)]
            (unless (valid-reason? reason)
              (error "Baseline reason must start with \"step N\", \"permanent: \", or \"unassigned: \""
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
  (let* ((terms (forbidden-terms))
         (actual (apply append (map (cut file-hits <> terms) (kernel-source-names))))
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
  (test-suite "kernel boundary (ADR 12)"
    (test-case "kernel imports only :gerbil, :std, and kernel modules"
      (check (problem-count (import-problems)) => 0))
    (test-case "kernel forbidden nouns do not exceed the baseline"
      (displayln "  kernel boundary: " (length (kernel-source-names)) " files checked; "
                 baseline-name " allows "
                 (foldl fx+ 0 (hash-values (baseline-limits (read-baseline))))
                 " known forbidden-noun hits")
      (check (problem-count (noun-problems)) => 0))))
