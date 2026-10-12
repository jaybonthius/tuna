;;; Mechanical checks of the kernel boundary (ADR 12, "Kernel contract").
;;;
;;; tuna/kernel/ may hold only Gerbil source and the baseline. Kernel source
;;; may import only :gerbil, :std, and kernel modules, may include only
;;; checked kernel files, and must not use the nouns ADR 12 forbids. Known
;;; noun hits are listed in boundary-baseline.sexp; the check fails on any
;;; hit beyond that list and on any entry larger than what remains, so the
;;; list can only shrink as the kernel cleanup
;;; (agents/plans/kernel-cleanup.md) lands.
(import (only-in :gerbil/runtime/hash HashTable)
        :std/misc/ports
        :std/source
        :std/test)
(export boundary-test)

;; ADR 12, "Kernel contract": the nouns the kernel must never know about.
;; Source text (code and comments) is split into lowercase words at every
;; non-alphanumeric character and at CamelCase boundaries; each term below
;; matches as that sequence of words, so "define-command" also matches
;; context-define-command! and "define command". Amend these lists
;; together with the ADR.
(def forbidden-words
  '("key" "keys" "keymap" "keymaps" "keyboard"
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
    "render" "renders" "rendered" "renderer" "rendering"
    "setting" "settings"
    "file" "files"
    "save" "saves" "saved" "saving" "autosave"
    "session" "sessions"
    "timer" "timers"
    "profile" "profiles" "profiler" "profiling"
    "latency"
    "measure" "measures" "measured" "measuring" "measurement" "measurements"
    "demo" "demos"))

;; ADR 12: the kernel has no command registry. The bare word "command"
;; stays allowed because the kernel announces commands starting and
;; finishing.
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

;;; The kernel tree

;; Every non-directory entry under tuna/kernel/, hidden ones included, as
;; (name . type) with NAME relative to the repository root.
(def (kernel-tree-entries) => :list
  (let walk ((dir "tuna/kernel"))
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

;; Entries other than regular .ss files and the baseline, so no other kind
;; of source can hide in the kernel, and exclusions naming no file.
(def (tree-problems) => :list
  (let (entries (kernel-tree-entries))
    (append
     (filter-map
      (lambda ((entry : :pair))
        (let ((name (car entry))
              (type (cdr entry)))
          (cond
           ((not (eq? type 'regular))
            (string-append name ": is a " (symbol->string type)
                           "; tuna/kernel/ may hold only .ss files and " baseline-name))
           ((or (string-suffix? ".ss" name) (equal? name baseline-name)) #f)
           (else
            (string-append name ": tuna/kernel/ may hold only .ss files and " baseline-name)))))
      entries)
     (filter-map
      (lambda ((name : :string))
        (and (not (assoc name entries))
             (string-append name ": listed in kernel-test-support-files but does not exist;"
                            " remove it from tuna/kernel/boundary-test.ss")))
      kernel-test-support-files))))

;; The checked files, relative to the repository root: the facade and every
;; non-test .ss file under tuna/kernel/.
(def (kernel-source-names) => :list
  (cons "tuna/kernel.ss"
        (filter (lambda ((name : :string))
                  (and (string-suffix? ".ss" name)
                       (not (string-suffix? "-test.ss" name))
                       (not (member name kernel-test-support-files))))
                (map car (filter (lambda ((entry : :pair)) (eq? (cdr entry) 'regular))
                                 (kernel-tree-entries))))))

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

;; Every path FORM includes, at any depth.
(def (included-paths (form : :t)) => :list
  (if (pair? form)
    (let (parts (elements form))
      (append (if (eq? (car form) 'include) (filter string? (cdr parts)) [])
              (apply append (map included-paths parts))))
    []))

(def (parent-segment? (name : :string)) => :boolean
  (and (member ".." (string-split name #\/)) #t))

;; Whether NAME, imported by the file named FILE, is :gerbil, :std, or a
;; kernel module.
(def (allowed-import? (file : :string) (name : :string)) => :boolean
  (cond
   ((parent-segment? name) #f)
   ((or (string-prefix? ":gerbil/" name) (string-prefix? ":std/" name)) #t)
   ((or (equal? name ":tuna/kernel") (string-prefix? ":tuna/kernel/" name)) #t)
   ((string-prefix? "./" name)
    (string-prefix? kernel-directory
                    (path-expand (substring name 2 (string-length name))
                                 (path-directory (source-path file)))))
   (else #f)))

;; Whether TARGET, included by the file named FILE, is a checked kernel file.
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

(def (import-problems) => :list
  (let (checked (kernel-source-names))
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
                        (and (not (allowed-import? file name))
                             (string-append file ": imports " name (where name)
                                            "; the kernel may import only :gerbil/..., :std/...,"
                                            " and kernel modules (ADR 12)")))
                      (imported-module-names forms))
                     (filter-map
                      (lambda ((target : :string))
                        (and (not (allowed-include? file target checked))
                             (string-append file ": includes " target (where target)
                                            "; the kernel may include only checked kernel files")))
                      (included-paths forms)))))
                checked))))

;;; Forbidden nouns

(def (word-char? (c : :char)) => :boolean
  (or (char-alphabetic? c) (char-numeric? c)))

(def (segment-cons (line : :string) (start : :fixnum) (end : :fixnum) (found : :list)) => :list
  (if (fx< start end)
    (cons (string-downcase (substring line start end)) found)
    found))

;; LINE's words, lowercased: runs of letters and digits, split again where
;; a lowercase letter meets a capital ("KeyEvent" gives "key" "event") and
;; before the last capital of an acronym ("HTTPServer" gives "http"
;; "server").
(def (line-segments (line : :string)) => :list
  (let (end (string-length line))
    (let lp ((i 0) (start 0) (found []))
      (if (fx= i end)
        (reverse (segment-cons line start end found))
        (let (c (string-ref line i))
          (cond
           ((not (word-char? c))
            (lp (fx1+ i) (fx1+ i) (segment-cons line start i found)))
           ((and (fx> i start)
                 (char-upper-case? c)
                 (let (previous (string-ref line (fx1- i)))
                   (or (char-lower-case? previous)
                       (and (char-upper-case? previous)
                            (fx< (fx1+ i) end)
                            (char-lower-case? (string-ref line (fx1+ i)))))))
            (lp (fx1+ i) i (segment-cons line start i found)))
           (else (lp (fx1+ i) start found))))))))

;; Every forbidden term's label, once: words, registry names, then plugin
;; names that are not already words.
(def (forbidden-labels) => :list
  (reverse
   (foldl (lambda ((label : :string) (found : :list))
            (if (member label found) found (cons label found)))
          []
          (append forbidden-words forbidden-registry-names (plugin-names)))))

;; First word -> the terms starting with it, each (label . words).
(def (term-index (labels : :list)) => HashTable
  (let (index (make-hash-table))
    (for-each (lambda ((label : :string))
                (let (words (string-split label #\-))
                  (hash-update! index (car words) (cut cons (cons label words) <>) [])))
              labels)
    index))

(def (phrase-at? (words : :list) (segments : :list)) => :boolean
  (or (null? words)
      (and (pair? segments)
           (equal? (car words) (car segments))
           (phrase-at? (cdr words) (cdr segments)))))

;; One (file, term) hit count, with the numbers of the lines it occurs on.
(defstruct hits ((file  : :string)
                 (label : :string)
                 (count : :fixnum)
                 (lines : :list))
  final: #t)

;; FILE's hits of the terms in INDEX, by label.
(def (file-hits (file : :string) (index : HashTable)) => :list
  (let (table (make-hash-table))            ; label -> (count . line numbers, newest first)
    (let lp ((lines (read-file-lines (source-path file))) (number 1))
      (when (pair? lines)
        (let scan ((segments (line-segments (car lines))))
          (when (pair? segments)
            (for-each (lambda ((term : :pair))
                        (when (phrase-at? (cdr term) segments)
                          (hash-update! table (car term)
                                        (lambda ((seen : :pair))
                                          (cons (fx1+ (car seen))
                                                (if (and (pair? (cdr seen)) (eqv? (cadr seen) number))
                                                  (cdr seen)
                                                  (cons number (cdr seen)))))
                                        (cons 0 []))))
                      (hash-ref index (car segments) []))
            (scan (cdr segments))))
        (lp (cdr lines) (fx1+ number))))
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
(def baseline-steps '("step 2" "step 3" "step 4" "step 5" "step 6" "step 7" "step 8"))

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
              (error "Baseline reason must be \"step N\" (N from 2 to 8) or \"permanent: <why>\""
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
  (test-suite "kernel boundary (ADR 12)"
    (test-case "tuna/kernel/ holds only .ss files and the baseline"
      (check (problem-count (tree-problems)) => 0))
    (test-case "kernel imports only :gerbil, :std, and kernel modules"
      (check (problem-count (import-problems)) => 0))
    (test-case "kernel forbidden nouns do not exceed the baseline"
      (displayln "  kernel boundary: " (length (kernel-source-names)) " files checked; "
                 baseline-name " allows "
                 (foldl fx+ 0 (hash-values (baseline-limits (read-baseline))))
                 " known forbidden-noun hits")
      (check (problem-count (noun-problems)) => 0))))
