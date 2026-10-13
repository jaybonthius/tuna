;;; Mechanical checks of the kernel and library boundaries (ADR 12, "Kernel
;;; contract"), and of who uses the program's own code.
;;;
;;; tuna/kernel/ may hold only Gerbil source and the baseline. Kernel source
;;; may import only :gerbil, :std, and kernel modules, may include only
;;; checked kernel files, and must not use the nouns ADR 12 forbids. Known
;;; noun hits are listed in boundary-baseline.sexp; the check fails on any
;;; hit beyond that list and on any entry larger than what remains, so the
;;; list can only shrink. After the kernel cleanup
;;; (agents/plans/kernel-cleanup.md) only permanent entries remain.
;;;
;;; tuna/lib/ may hold only Gerbil source. Library source may import only
;;; :gerbil, :std, the kernel facade :tuna/kernel, and library modules, and
;;; may include only checked library files. Libraries may use the nouns.
;;;
;;; Test support (tuna/test-support/) is for tests and the demo only: no
;;; other non-test source under tuna/, and nothing under starter/, may
;;; import or include it, and build.ss must not list it. The demo (demo/)
;;; is for development only: nothing under tuna/, tests included, or under
;;; starter/ may import or include it, and build.ss must not list it. The kernel object is private: outside tuna/kernel/ and test support,
;;; source and tests may import only the kernel facade :tuna/kernel, never
;;; a module under tuna/kernel/.
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
;; (:tuna/<dir>), the other files the directory may hold, and the modules
;; it may import besides :gerbil/..., :std/..., and its own checked modules.
(defstruct layer ((name         : :string)
                  (directory    : :string)
                  (facade       :? :string)
                  (extra-files  : :list)
                  (also-imports : :list))
  final: #t)

;; The kernel: its facade tuna/kernel.ss and tuna/kernel/.
(def kernel-layer
  (make-layer "kernel" "tuna/kernel" "tuna/kernel.ss" [baseline-name] []))

;; Shared libraries, built only on the public kernel API: no kernel
;; module other than the facade, no contract, no plugin, no prelude.
(def library-layer
  (make-layer "library" "tuna/lib" #f [] [":tuna/kernel"]))

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
;; other kind of source can hide in the layer.
(def (tree-problems (l : layer)) => :list
  (let (allowed (string-append (layer-directory l) "/ may hold only .ss files"
                               (apply string-append
                                      (map (cut string-append " and " <>) (layer-extra-files l)))))
    (filter-map
     (lambda ((entry : :pair))
       (let ((name (car entry))
             (type (cdr entry)))
         (cond
          ((not (eq? type 'regular))
           (string-append name ": is a " (symbol->string type) "; " allowed))
          ((or (string-suffix? ".ss" name) (member name (layer-extra-files l))) #f)
          (else (string-append name ": " allowed)))))
     (tree-entries (layer-directory l)))))

;; The checked files of L, relative to the repository root: its facade and
;; every non-test .ss file under its directory.
(def (layer-source-names (l : layer)) => :list
  (let (files (filter (lambda ((name : :string))
                        (and (string-suffix? ".ss" name)
                             (not (string-suffix? "-test.ss" name))))
                      (map car (filter (lambda ((entry : :pair)) (eq? (cdr entry) 'regular))
                                       (tree-entries (layer-directory l))))))
    (if (layer-facade l) (cons (layer-facade l) files) files)))

(def (kernel-source-names) => :list
  (layer-source-names kernel-layer))

;; Whether FORM, at any depth, defines the plugin STEM-plugin or STEM with
;; defplugin, as (defplugin name ...) or (defplugin (name ctx) ...).
(def (defines-plugin-named? (form : :t) (stem : :string)) => :boolean
  (and (pair? form)
       (or (and (eq? (car form) 'defplugin)
                (pair? (cdr form))
                (let (head (if (pair? (cadr form)) (car (cadr form)) (cadr form)))
                  (and (symbol? head)
                       (member (symbol->string head) [stem (string-append stem "-plugin")])
                       #t)))
           (defines-plugin-named? (car form) stem)
           (defines-plugin-named? (cdr form) stem))))

;; Plugins whose modules are not in tuna/plugins/: the stems of the non-test
;; files under tuna/test-support/ and demo/, and of tuna/config-blocks.ss,
;; that define a plugin named after their file (contract doubles, fixtures,
;; the demo, the start-up code's config-blocks). Files whose plugins have
;; other names, such as no-session-plugin in session.ss, are not plugin
;; names.
(def (plugin-names-elsewhere) => :list
  (filter-map (lambda ((file : :string))
                (let (stem (path-strip-extension (path-strip-directory file)))
                  (and (string-suffix? ".ss" file)
                       (not (string-suffix? "-test.ss" file))
                       (defines-plugin-named? (read-forms (source-path file)) stem)
                       stem)))
              (append (map car (tree-entries "tuna/test-support"))
                      (map car (tree-entries "demo"))
                      ["tuna/config-blocks.ss"])))

;; Plugin names, from the module files in tuna/plugins/, and those above.
(def (plugin-names) => :list
  (list-sort string<?
             (append (plugin-names-elsewhere)
                     (map path-strip-extension
                          (filter (lambda ((file : :string))
                                    (and (string-suffix? ".ss" file)
                                         (not (string-suffix? "-test.ss" file))))
                                  (directory-files (path-expand "plugins" tuna-directory)))))))

;;; Imports and includes

;; The top-level forms of the file at PATH. A first line "#lang PRELUDE
;; ...", which the reader cannot read, becomes the form (import PRELUDE):
;; as Gerbil does (read-lang in gerbil/expander/module.ss), the rest of the
;; line is read as data, and its first datum, a symbol or a string, is the
;; prelude.
(def (read-forms (path : :string)) => :list
  (let* ((source (read-file-string path))
         (lang? (string-prefix? "#lang " source))
         (end (if lang? (or (string-index source #\newline) (string-length source)) 0))
         (port (open-input-string (substring source end (string-length source)))))
    (let lp ((forms (if lang?
                      (match (call-with-input-string (substring source 6 end) (cut read-all <> read))
                        ([prelude . _] [['import prelude]])
                        (else (error "#lang line names no prelude" path)))
                      [])))
      (let (form (read port))
        (if (eof-object? form)
          (reverse forms)
          (lp (cons form forms)))))))

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
;; allowed modules, or a checked module of L; test files are not.
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

;;; Test support and the private kernel

(def test-support-directory "tuna/test-support")

;; PATH with "." and ".." segments resolved without touching the file
;; system, as path-expand leaves them in.
(def (lexical-path (path : :string)) => :string
  (let lp ((segments (string-split path #\/)) (kept []))
    (match segments
      ([] (string-join (reverse kept) "/"))
      (["." . more] (lp more kept))
      ([".." . more] (lp more (if (and (pair? kept) (not (equal? (car kept) ""))) (cdr kept) kept)))
      ([segment . more] (lp more (cons segment kept))))))

;; The source NAME refers to when FILE imports or includes it: a module
;; :a/b as the root-relative a/b, or a path relative to FILE, without
;; extension, as an absolute path.
(def (reference-target (file : :string) (name : :string)) => :string
  (if (string-prefix? ":" name)
    (source-path (substring name 1 (string-length name)))
    (lexical-path (path-expand name (path-directory (source-path file))))))

;; Whether NAME, imported or included by FILE, is in DIRECTORY (relative to
;; the repository root).
(def (name-within? (file : :string) (name : :string) (directory : :string)) => :boolean
  (string-prefix? (string-append (source-path directory) "/") (reference-target file name)))

;; Whether NAME, imported or included by FILE, is tuna/test-support/ or in it.
(def (test-support-name? (file : :string) (name : :string)) => :boolean
  (or (equal? (reference-target file name) (source-path test-support-directory))
      (name-within? file name test-support-directory)))

;; Every module name, module-like symbol, and included path in FORMS.
(def (referenced-names (forms : :list)) => :list
  (unique (append (imported-module-names forms)
                  (module-like-symbols forms)
                  (included-paths forms))))

;; Every .ss file under tuna/ other than tests and test support itself.
(def (non-test-source-names) => :list
  (filter (lambda ((name : :string))
            (and (string-suffix? ".ss" name)
                 (not (string-suffix? "-test.ss" name))
                 (not (string-prefix? (string-append test-support-directory "/") name))))
          (map car (tree-entries "tuna"))))

(def starter-directory "starter")

;; Every .ss file under starter/.
(def (starter-source-names) => :list
  (filter (cut string-suffix? ".ss" <>) (map car (tree-entries starter-directory))))

(def (test-support-problems) => :list
  (apply append
         (map (lambda ((file : :string))
                (filter-map
                 (lambda ((name : :string))
                   (and (test-support-name? file name)
                        (string-append file ": imports or includes " name
                                       "; only tests and the demo may use " test-support-directory "/")))
                 (referenced-names (read-forms (source-path file)))))
              (append (non-test-source-names) (starter-source-names)))))

;;; The demo

(def demo-directory "demo")

;; Every .ss file under tuna/, tests included, and under starter/.
(def (demo-client-names) => :list
  (append (filter (cut string-suffix? ".ss" <>) (map car (tree-entries "tuna")))
          (starter-source-names)))

;; Imports or includes of demo/ by Tuna's package, its tests, or the
;; starter configuration: the demo is for development only.
(def (demo-problems) => :list
  (apply append
         (map (lambda ((file : :string))
                (filter-map
                 (lambda ((name : :string))
                   (and (or (equal? (reference-target file name) (source-path demo-directory))
                            (name-within? file name demo-directory))
                        (string-append file ": imports or includes " name
                                       "; nothing in tuna/ or starter/ may use " demo-directory "/")))
                 (referenced-names (read-forms (source-path file)))))
              (demo-client-names))))

;; Every string in FORM, at any depth.
(def (strings-in (form : :t)) => :list
  (cond
   ((pair? form) (append (strings-in (car form)) (strings-in (cdr form))))
   ((vector? form) (strings-in (vector->list form)))
   ((string? form) [form])
   (else [])))

;; build.ss entries under DIRECTORY, which gerbil build would compile into
;; the package.
(def (build-script-problems (directory : :string) (what : :string)) => :list
  (filter-map (lambda ((name : :string))
                (and (or (equal? name directory)
                         (string-prefix? (string-append directory "/") name))
                     (string-append "build.ss: lists " name "; " what " must not be built")))
              (strings-in (read-forms (source-path "build.ss")))))

;; Every .ss file under tuna/, tests included, other than the kernel (its
;; facade tuna/kernel.ss and tuna/kernel/) and test support.
(def (kernel-client-names) => :list
  (filter (lambda ((name : :string))
            (and (string-suffix? ".ss" name)
                 (not (equal? name "tuna/kernel.ss"))
                 (not (string-prefix? "tuna/kernel/" name))
                 (not (string-prefix? (string-append test-support-directory "/") name))))
          (map car (tree-entries "tuna"))))

;; Imports or includes of a module under tuna/kernel/ by a kernel client,
;; which bypass the facade and may reach the private kernel object.
(def (kernel-internal-problems) => :list
  (apply append
         (map (lambda ((file : :string))
                (filter-map
                 (lambda ((name : :string))
                   (and (name-within? file name "tuna/kernel")
                        (string-append file ": imports or includes " name
                                       "; outside the kernel and test support, use only"
                                       " the kernel facade :tuna/kernel")))
                 (referenced-names (read-forms (source-path file)))))
              (kernel-client-names))))

;;; Program code

;; The program's start-up, reload, and command-line code (ADR 12,
;; amendment for configuration stage 2), with config-blocks, which the
;; start-up code turns on itself: only the program uses it.
;; Plugins reach reload and the configuration report through the
;; configuration service (tuna/services/configuration.ss).
(def program-modules '("tuna/main" "tuna/boot" "tuna/control" "tuna/config-blocks"))
(def program-files '("tuna/main.ss" "tuna/boot.ss" "tuna/control.ss" "tuna/config-blocks.ss"))

(def (program-code-problems) => :list
  (apply append
         (map (lambda ((file : :string))
                (filter-map
                 (lambda ((name : :string))
                   (let (target (find (lambda ((module : :string))
                                        (equal? (reference-target file name) (source-path module)))
                                      program-modules))
                     (and target
                          (string-append file ": imports or includes " name
                                         "; only the program (" (string-join program-files ", ")
                                         ") uses program code"))))
                 (referenced-names (read-forms (source-path file)))))
              (filter (lambda ((file : :string)) (not (member file program-files)))
                      (non-test-source-names)))))

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

;; The kernel-cleanup plan steps that remove baseline entries. None
;; remain, so every entry must give a "permanent: <why>" reason.
(def baseline-steps '())

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
              (error "Baseline reason must be \"permanent: <why>\"; no kernel-cleanup step remains in baseline-steps"
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
                 " known forbidden-noun hits; plugin names outside tuna/plugins/: "
                 (string-join (plugin-names-elsewhere) ", "))
      (check (problem-count (noun-problems)) => 0))
    (test-case "tuna/lib/ holds only .ss files"
      (check (problem-count (tree-problems library-layer)) => 0))
    (test-case "libraries import only :gerbil, :std, :tuna/kernel, and library modules"
      (displayln "  library boundary: " (length (layer-source-names library-layer)) " files checked")
      (check (problem-count (import-problems library-layer)) => 0))
    (test-case "only tests and the demo import or include test support, and build.ss does not list it"
      (displayln "  test-support boundary: "
                 (length (append (non-test-source-names) (starter-source-names)))
                 " non-test files checked")
      (check (problem-count (append (test-support-problems)
                                    (build-script-problems test-support-directory "test support")))
             => 0))
    (test-case "nothing in tuna/ or starter/ imports or includes the demo, and build.ss does not list it"
      (displayln "  demo boundary: " (length (demo-client-names)) " files checked")
      (check (problem-count (append (demo-problems)
                                    (build-script-problems demo-directory "the demo")))
             => 0))
    (test-case "outside the kernel and test support, only the kernel facade is imported"
      (displayln "  kernel facade boundary: " (length (kernel-client-names)) " files checked")
      (check (problem-count (kernel-internal-problems)) => 0))
    (test-case "only the program imports program code"
      (check (problem-count (program-code-problems)) => 0))))
