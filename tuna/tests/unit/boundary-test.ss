;;; Package and kernel boundaries (ADR 12 and package-layout plan).
;;; This suite reads source, including nested/quoted imports and includes;
;;; Gerbil's shared load path does not enforce package ownership.
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
(def root-directory
  (path-normalize (path-expand "../../../" (this-source-directory))))

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
  (make-layer "kernel" "tuna/kernel" "tuna/kernel.ss" [] []))

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
(def (tree-entry-problems (l : layer) (entries : :list)) => :list
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
     entries)))

(def (tree-problems (l : layer)) => :list
  (tree-entry-problems l (tree-entries (layer-directory l))))

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

(def (test-source? (file : :string)) => :boolean
  (and (member "tests" (string-split file #\/)) #t))

(def (source-names (directory : :string)) => :list
  (filter (cut string-suffix? ".ss" <>) (map car (tree-entries directory))))

(def (production-source-names) => :list
  (filter (lambda ((file : :string)) (not (test-source? file)))
          (append (source-names "tuna") (source-names "plugins"))))

(def (all-source-names) => :list
  (apply append (map source-names '("tuna" "plugins" "tests" "starter" "demo"))))

;; Plugin bindings distinguish source-only feature fixtures from helpers.
(def (defined-plugin-names (form : :t)) => :list
  (if (pair? form)
    (if (and (eq? (car form) 'defplugin) (pair? (cdr form)))
      (let (head (if (pair? (cadr form)) (caadr form) (cadr form)))
        (if (symbol? head) [(symbol->string head)] []))
      (append (defined-plugin-names (car form)) (defined-plugin-names (cdr form))))
    []))


;; New packages and source-only doubles automatically become forbidden kernel
;; vocabulary. "completion" and "annotations" also name concurrency
;; primitives and Gerbil type declarations, not just editor features.
(def (plugin-package-directories) => :list
  (filter-map (lambda ((name : :string))
                (let (directory (string-append "plugins/" name))
                  (and (file-exists? (source-path (string-append directory "/gerbil.pkg"))) directory)))
              (list-sort string<? (directory-files (source-path "plugins")))))

(def (feature-names) => :list
  (unique
   (filter (lambda ((name : :string)) (not (member name '("completion" "annotations"))))
    (append
     (map path-strip-directory (plugin-package-directories))
     (apply append
       (map (lambda ((file : :string))
              (apply append (map defined-plugin-names (read-forms (source-path file)))))
            (append (filter (lambda ((file : :string))
                              (or (not (test-source? file))
                                  (string-contains file "/tests/support/")))
                            (source-names "plugins"))
                    (source-names "demo")
                    ;; Configuration fixtures exercise generic plugin/runtime vocabulary.
                    (filter (lambda ((file : :string)) (not (equal? file "tests/support/config.ss")))
                            (source-names "tests/support")))))))))

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

;;; Package references

;; Resolve dot segments without requiring a file to exist (negative tests
;; deliberately name hypothetical files).
(def (lexical-path (path : :string)) => :string
  (let lp ((segments (string-split path #\/)) (kept []))
    (match segments
      ([] (string-join (reverse kept) "/"))
      (["." . more] (lp more kept))
      ([".." . more] (lp more (if (and (pair? kept) (not (equal? (car kept) ""))) (cdr kept) kept)))
      ([segment . more] (lp more (cons segment kept))))))

;; Module ids use the gerbil.pkg prefix, not the repository directory.
(def (reference-target (file : :string) (name : :string)) => :string
  (let (path
         (cond
           ((string-prefix? ":tuna/plugins/" name)
            (source-path (substring name (string-length ":tuna/") (string-length name))))
           ((string-prefix? ":" name) (source-path (substring name 1 (string-length name))))
           (else (path-expand name (path-directory (source-path file))))))
    (path-strip-extension (lexical-path path))))

(def (name-within? (file : :string) (name : :string) (directory : :string)) => :boolean
  (string-prefix? (string-append (source-path directory) "/") (reference-target file name)))

(def (support-file? (file : :string)) => :boolean
  (or (string-prefix? "tests/support/" file)
      (and (string-contains file "/tests/support/") #t)))

(def (test-support-name? (file : :string) (name : :string)) => :boolean
  (let (target (reference-target file name))
    (or (string-suffix? "/tests/support" target)
        (and (string-contains target "/tests/support/") #t))))

(def (referenced-names (forms : :list)) => :list
  (unique (append (imported-module-names forms)
                  (module-like-symbols forms)
                  (included-paths forms))))

(def (references (file : :string)) => :list
  (referenced-names (read-forms (source-path file))))

(def (test-support-reference-problems (file : :string) (names : :list)) => :list
  (filter-map
    (lambda ((name : :string))
      (and (test-support-name? file name)
           (not (or (test-source? file) (string-prefix? "demo/" file)))
           (string-append file ": imports or includes " name "; only tests and the demo use test support")))
    names))

(def (test-support-problems) => :list
  (apply append (map (lambda ((file : :string))
                       (test-support-reference-problems file (references file)))
                     (all-source-names))))

;; A demo may use plugin fixtures/doubles, never the helper that selects a
;; fresh private kernel. Relative imports remain source-only.
(def (demo-support-allowed? (file : :string) (name : :string)) => :boolean
  (let (target (string-append (reference-target file name) ".ss"))
    (and (file-exists? target)
         (pair? (defined-plugin-names (read-forms target)))
         #t)))

(def (demo-test-support-problems) => :list
  (apply append
    (map (lambda ((file : :string))
           (filter-map
             (lambda ((name : :string))
               (and (test-support-name? file name)
                    (not (demo-support-allowed? file name))
                    (string-append file ": demo imports non-plugin test helper " name)))
             (references file)))
         (source-names "demo"))))

(def (demo-reference-problems (file : :string) (names : :list)) => :list
  (filter-map
    (lambda ((name : :string))
      (and (not (string-prefix? "demo/" file))
           (name-within? file name "demo")
           (string-append file ": imports the demo " name)))
    names))

;; Tests and doubles never enter any package's production build specs.
(def (strings-in (form : :t)) => :list
  (cond
    ((pair? form) (append (strings-in (car form)) (strings-in (cdr form))))
    ((vector? form) (strings-in (vector->list form)))
    ((string? form) [form])
    (else [])))

(def (build-reference-problems (names : :list)) => :list
  (filter-map
    (lambda ((name : :string))
      (and (or (member "tests" (string-split name #\/))
               (member "demo" (string-split name #\/)))
           (string-append "build.ss: lists development source " name)))
    names))

;; Only the kernel's own white-box tests and kernel-only support may
;; reach its private modules. Plugin tests do not gain that privilege.
(def (kernel-private-client? (file : :string)) => :boolean
  (or (equal? file "tuna/kernel.ss")
      (string-prefix? "tuna/kernel/" file)
      (and (member file '("tuna/tests/unit/loop-test.ss" "tuna/tests/unit/plugins-test.ss"
                          "tuna/tests/unit/service-cache-test.ss" "tuna/tests/support/kernel.ss"))
           #t)))

(def (kernel-reference-problems (file : :string) (names : :list)) => :list
  (filter-map
    (lambda ((name : :string))
      (and (name-within? file name "tuna/kernel")
           (not (or (kernel-private-client? file)
                    ;; The configuration gate alone calls raw activation.
                    (and (equal? file "tuna/plugin-use.ss")
                         (equal? (reference-target file name)
                                 (source-path "tuna/kernel/plugins")))))
           (string-append file ": imports private kernel module " name "; use :tuna/kernel")))
    names))

(def (program-files) => :list
  (filter (lambda ((file : :string))
            (and (fx= (length (string-split file #\/)) 2)
                 (not (public-tuna-target? (source-path (path-strip-extension file))))))
          (source-names "tuna")))

(def (program-reference-problems (file : :string) (names : :list)) => :list
  (filter-map
    (lambda ((name : :string))
      (and (not (or (member file (program-files)) (test-source? file)))
           (member (string-append (reference-target file name) ".ss") (map source-path (program-files)))
           (string-append file ": only the program uses program code " name)))
    names))

(def (tuna-reference-problems (file : :string) (names : :list)) => :list
  (filter-map
    (lambda ((name : :string))
      (and (or (name-within? file name "plugins")
               ;; Reject a stale module name too, not just the new prefix.
               (name-within? file name "tuna/services"))
           (string-append file ": imports " name "; Tuna imports no editor package")))
    names))

;; Ownership comes from the package directory and declared module prefix.
(def (package-owner (target : :string)) => (Maybe :string)
  (cond
    ((string-prefix? (source-path "plugins/") target)
     (let (tail (substring target (string-length (source-path "plugins/")) (string-length target)))
       (string-append "plugins/" (car (string-split tail #\/)))))
    ((string-prefix? (source-path "tuna/") target) "tuna")
    (else #f)))

(def (public-tuna-target? (target : :string)) => :boolean
  (or (and (member target (map source-path '("tuna/kernel" "tuna/configuration" "tuna/prelude"
                                            "tuna/config" "tuna/version"))) #t)
      (string-prefix? (source-path "tuna/lib/") target)))

(def (external-reference? (name : :string)) => :boolean
  (and (string-prefix? ":" name)
       (not (or (string-prefix? ":tuna/" name)
                (string-prefix? ":tests/" name)
                (string-prefix? ":demo/" name)))
       #t))

(def (package-reference-allowed? (file : :string) (name : :string)) => :boolean
  (let* ((target (reference-target file name))
         (owner (package-owner (source-path file)))
         (other (package-owner target)))
    (and (not (test-support-name? file name))
         (or (external-reference? name)
             (public-tuna-target? target)
             (and other (equal? other owner))
             (and other (string-prefix? "plugins/" other)
                  (equal? target (source-path (string-append other "/contract")))))
         #t)))

(def (plugin-reference-problems (file : :string) (names : :list)) => :list
  (filter-map
    (lambda ((name : :string))
      (and (not (package-reference-allowed? file name))
           (string-append file ": imports or includes " name
                          "; a plugin uses Tuna public modules, contracts and its own files only")))
    names))

(def (re-exports? (form : :t)) => :boolean
  (and (pair? form)
       (or (eq? (car form) 'import:)
           (re-exports? (car form))
           (re-exports? (cdr form)))))

(def (contract-source? (file : :string)) => :boolean
  (or (equal? file "tuna/configuration.ss")
      (string-suffix? "/contract.ss" file)))

(def (contract-reference-allowed? (file : :string) (name : :string)) => :boolean
  (let (target (reference-target file name))
    (or (external-reference? name)
        (equal? target (source-path "tuna/kernel"))
        (string-prefix? (source-path "tuna/lib/") target)
        (and (contract-source? (string-append target ".ss"))
             (file-exists? (string-append target ".ss"))))))

(def (contract-problems) => :list
  (apply append
    (map (lambda ((file : :string))
           (append
             (filter-map (lambda ((name : :string))
                           (and (not (contract-reference-allowed? file name))
                                (string-append file ": contract imports non-contract " name)))
                         (references file))
             (if (re-exports? (read-forms (source-path file)))
               [(string-append file ": contracts never re-export another module")]
               [])))
         (filter contract-source? (production-source-names)))))

;; Collapsing an acyclic module graph into packages can still create a
;; cycle: include every production contract, implementation and private file.
(def (package-graph) => :list
  (let (graph (make-hash-table))
    (for-each
      (lambda ((file : :string))
        (let (owner (package-owner (source-path file)))
          (hash-update! graph owner
            (lambda ((edges : :list))
              (unique (append edges
                        (filter-map (lambda ((name : :string))
                                      (let (other (package-owner (reference-target file name)))
                                        (and other (not (equal? owner other)) other)))
                                    (references file)))))
            [])))
      (production-source-names))
    (map (lambda ((owner : :string)) (cons owner (hash-ref graph owner)))
         (list-sort string<? (hash-keys graph)))))

;; Read the declarative package list, never execute build.ss in a test.
(def (built-package-directories) => :list
  (match (find (lambda (form) (and (pair? form) (eq? (car form) 'def)
                                  (pair? (cdr form)) (eq? (cadr form) 'packages)))
               (read-forms (source-path "build.ss")))
    (['def 'packages ['quasiquote packages]] (map car packages))
    (else (error "build.ss has no declarative packages list"))))

(def (unbuilt-packages (packages : :list) (built : :list)) => :list
  (filter (lambda ((package : :string)) (not (member package built))) packages))

(def (graph-cycle-problems (graph : :list)) => :list
  (let ((done []) (problems []))
    (let visit ((file #f) (path []))
      (cond
        ((not file) (for-each (lambda (row) (visit (car row) [])) graph))
        ((member file path)
         (set! problems (cons (string-append "package cycle: "
                               (string-join (reverse (cons file path)) " -> ")) problems)))
        ((not (member file done))
         (let (row (assoc file graph))
           (when row
             (for-each (lambda (dependency) (visit dependency (cons file path))) (cdr row))))
         (set! done (cons file done)))))
    (reverse problems)))

(def (source-reference-problems (check : :procedure) (files : :list)) => :list
  (apply append (map (lambda ((file : :string)) (check file (references file))) files)))

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
  (unique (append forbidden-words forbidden-registry-names (feature-names))))

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

;; Fixed exceptions to the forbidden vocabulary, not a cleanup budget.
;; The two "keys" hits are Gerbil's hash-keys; "position" is Gambit's
;; ##locat-start-position used to record a plugin definition's source.
(def noun-allowlist
  '(("tuna/kernel/entries.ss" "keys" 1)
    ("tuna/kernel/plugins.ss" "keys" 1)
    ("tuna/kernel/plugins.ss" "position" 1)
    ;; Generic service facades, not editor layout vocabulary. Exact counts
    ;; keep every other use of the forbidden term subject to this check.
    ("tuna/kernel/plugins.ss" "view" 4)
    ("tuna/kernel.ss" "view" 8)
    ("tuna/kernel/service-interface.ss" "view" 11)))

(def (noun-problems) => :list
  (let* ((index (term-index (forbidden-labels)))
         (actual (apply append (map (cut file-hits <> index) (kernel-source-names))))
         (counts (let (table (make-hash-table))
                   (for-each (lambda ((h : hits))
                               (hash-put! table (cons (hits-file h) (hits-label h)) (hits-count h)))
                             actual)
                   table))
         (limits (let (table (make-hash-table))
                   (for-each (lambda (entry) (hash-put! table (cons (car entry) (cadr entry)) (caddr entry)))
                             noun-allowlist)
                   table)))
    (append
     (filter-map
      (lambda ((h : hits))
        (let (limit (hash-ref limits (cons (hits-file h) (hits-label h)) 0))
          (and (fx> (hits-count h) limit)
               (string-append (hits-file h) ": forbidden term \"" (hits-label h) "\" has "
                              (number->string (hits-count h)) " hits, allowlist allows "
                              (number->string limit) " (lines "
                              (number-list (hits-lines h)) ")"))))
      actual)
     (filter-map
      (lambda ((key : :pair))
        (let ((limit (hash-ref limits key))
              (count (hash-ref counts key 0)))
          (and (fx> limit count)
               (string-append (car key) ": allowlist allows " (number->string limit)
                              " hits of \"" (cdr key) "\" but only " (number->string count)
                              " remain; update the fixed noun-allowlist"))))
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
  (test-suite "package and kernel boundaries (ADR 12)"
    (test-case "kernel tree holds only Gerbil source"
      (check (problem-count (tree-problems kernel-layer)) => 0)
      (check (length (tree-entry-problems kernel-layer '(("tuna/kernel/hidden.c" . regular)))) => 1)
      (check (allowed-include? "tuna/kernel/plugins.ss" "../boot.ss" (kernel-source-names)) => #f))
    (test-case "kernel imports only Gerbil standard library and its own modules"
      (check (problem-count (import-problems kernel-layer)) => 0)
      (check (allowed-import? kernel-layer "tuna/kernel/plugins.ss" ":tuna/configuration" (kernel-source-names)) => #f)
      (check (allowed-import? kernel-layer "tuna/kernel/plugins.ss" ":tuna/kernel/ids" (kernel-source-names)) => #t))
    (test-case "kernel forbidden nouns match the fixed allowlist"
      (check (problem-count (noun-problems)) => 0)
      (check (phrase-at? '("define" "command") '(("define" . 1) ("command" . 2))) => #t)
      (check (line-segments "contextDefineCommand! key2 HTTPServer")
             => '("context" "define" "command" "key" "2" "http" "server")))
    (test-case "libraries hold only Gerbil source"
      (check (problem-count (tree-problems library-layer)) => 0)
      (check (length (tree-entry-problems library-layer '(("tuna/lib/hidden.ss" . symbolic-link)))) => 1))
    (test-case "libraries import only kernel facade libraries and standard modules"
      (check (problem-count (import-problems library-layer)) => 0)
      (check (allowed-import? library-layer "tuna/lib/jobs.ss" ":tuna/plugins/buffers/contract"
                              (layer-source-names library-layer)) => #f)
      (check (allowed-import? library-layer "tuna/lib/jobs.ss" ":tuna/kernel/state"
                              (layer-source-names library-layer)) => #f))
    (test-case "module prefixes and relative paths resolve to package source"
      (check (reference-target "plugins/keys/plugin.ss" ":tuna/plugins/layout/contract")
             => (source-path "plugins/layout/contract"))
      (check (reference-target "plugins/keys/plugin.ss" "../layout/./tree")
             => (source-path "plugins/layout/tree"))
      (check (reference-target "plugins/keys/plugin.ss" ":tuna/kernel") => (source-path "tuna/kernel")))
    (test-case "Tuna imports no editor package or stale central contract"
      (check (problem-count (source-reference-problems tuna-reference-problems
                              (filter (cut string-prefix? "tuna/" <>) (production-source-names)))) => 0)
      (check (tuna-reference-problems "tuna/boot.ss" '(":tuna/configuration")) => [])
      (check (length (tuna-reference-problems "tuna/boot.ss"
                       '(":tuna/plugins/session/contract" "../plugins/keys/plugin" ":tuna/services/session"))) => 3))
    (test-case "plugin packages use only public Tuna contracts and their own files"
      (check (problem-count (source-reference-problems plugin-reference-problems
                              (filter (cut string-prefix? "plugins/" <>) (production-source-names)))) => 0)
      (check (plugin-reference-problems "plugins/layout/plugin.ss"
               '("./tree" ":tuna/plugins/layout/contract" ":tuna/plugins/keys/contract"
                 ":tuna/kernel" ":tuna/lib/jobs" ":tuna/configuration" ":tuna/prelude")) => []))
    (test-case "another package's implementation or private module is forbidden"
      (check (length (plugin-reference-problems "plugins/keys/plugin.ss"
                       '(":tuna/plugins/layout/plugin" ":tuna/plugins/layout/tree" "../layout/tree"))) => 3)
      (check (length (plugin-reference-problems "plugins/keys/private/nested.ss"
                       '("../../layout/plugin"))) => 1))
    (test-case "contracts import only lower layers and contract vocabulary"
      (check (problem-count (contract-problems)) => 0)
      (check (contract-reference-allowed? "plugins/keys/contract.ss" ":tuna/plugins/keys/plugin") => #f)
      (check (contract-reference-allowed? "plugins/keys/contract.ss" "../layout/tree") => #f))
    (test-case "contracts never re-export modules even inside macro templates"
      (check (re-exports? '(export (phi: +1 (import: :tuna/plugins/commands/contract)))) => #t)
      (check (re-exports? '(export own-name)) => #f))
    (test-case "plugin implementations use the live-redefinition prelude"
      (for-each
       (lambda ((directory : :string))
         (check (string-prefix? "#lang :tuna/prelude\n"
                  (read-file-string (source-path (string-append directory "/plugin.ss")))) => #t))
       (plugin-package-directories)))
    (test-case "build.ss lists every plugin package"
      (check (unbuilt-packages (plugin-package-directories) (built-package-directories)) => [])
      (check (unbuilt-packages '("plugins/a" "plugins/new") '("tuna" "plugins/a"))
             => '("plugins/new")))
    (test-case "kernel feature vocabulary follows packages and plugin declarations"
      (check (member "completion-vertical" (feature-names)) ? pair?)
      (check (member "two-views" (feature-names)) ? pair?)
      (check (member "completion" (feature-names)) => #f))
    (test-case "production package imports form a directed acyclic graph"
      (displayln "  package boundary: " (length (package-graph)) " packages checked")
      (check (problem-count (graph-cycle-problems (package-graph))) => 0))
    (test-case "cycle detection rejects self-imports and indirect package cycles"
      (check (length (graph-cycle-problems '(("a" "a")))) => 1)
      (check (length (graph-cycle-problems '(("a" "b") ("b" "c") ("c" "a")))) => 1)
      (check (graph-cycle-problems '(("a" "b" "c") ("b" "c") ("c"))) => []))
    (test-case "only tests and the demo use root or package test support"
      (check (problem-count (test-support-problems)) => 0)
      (check (length (test-support-reference-problems "starter/init.ss"
                       '("../tests/support/config" ":tuna/tests/support/kernel"
                         ":tuna/plugins/layout/tests/support/two-views"))) => 3)
      (check (test-support-reference-problems "plugins/layout/tests/unit/tree-test.ss"
               '("../support/two-views")) => [])
      (check (test-support-reference-problems "demo/init.ss"
               '("../plugins/layout/tests/support/two-views")) => []))
    (test-case "demo uses only plugin fixtures and contract doubles"
      (check (problem-count (demo-test-support-problems)) => 0)
      (check (demo-support-allowed? "demo/init.ss" ":tuna/tests/support/kernel") => #f)
      (check (length (kernel-reference-problems "demo/demo.ss" '(":tuna/kernel/state"))) => 1))
    (test-case "production build specs contain no tests test support or demo"
      (check (problem-count (build-reference-problems (strings-in (read-forms (source-path "build.ss"))))) => 0)
      (check (length (build-reference-problems '("tests/support/config" "tests/unit/tree-test" "demo/demo"))) => 3))
    (test-case "Tuna plugins tests and starter never import the demo"
      (check (problem-count (source-reference-problems demo-reference-problems (all-source-names))) => 0)
      (check (length (demo-reference-problems "tests/integration/editor-test.ss" '("../../demo/demo"))) => 1))
    (test-case "kernel internals are private even from plugin tests"
      (check (problem-count (source-reference-problems kernel-reference-problems (all-source-names))) => 0)
      (check (length (kernel-reference-problems "plugins/keys/tests/unit/plugin-test.ss"
                       '(":tuna/kernel/state" "../../../../tuna/kernel/entries"))) => 2)
      (check (kernel-reference-problems "tuna/tests/unit/plugins-test.ss" '(":tuna/kernel/state")) => [])
      (check (kernel-reference-problems "tuna/tests/unit/service-cache-test.ss"
               '(":tuna/kernel/state" ":tuna/kernel/plugins")) => [])
      (check (length (kernel-reference-problems "tuna/tests/unit/jobs-test.ss" '(":tuna/kernel/state"))) => 1)
      (check (kernel-reference-problems "tuna/plugin-use.ss" '(":tuna/kernel/plugins")) => [])
      (check (length (kernel-reference-problems "tuna/plugin-use.ss" '(":tuna/kernel/state"))) => 1))
    (test-case "program code stays private from features and demo"
      (check (problem-count (source-reference-problems program-reference-problems (all-source-names))) => 0)
      (check (length (program-reference-problems "plugins/reload-config/plugin.ss" '(":tuna/boot"))) => 1)
      (check (length (plugin-reference-problems "plugins/keys/plugin.ss" '(":tuna/control"))) => 1))
    (test-case "nested import forms quoted module names and includes are checked"
      (check (referenced-names '((import (only-in :tuna/plugins/layout/tree secret))
                                (quote :tuna/plugins/keys/plugin)
                                (include "../layout/private.ss")))
             => '(":tuna/plugins/layout/tree" ":tuna/plugins/keys/plugin" "../layout/private.ss")))
    (test-case "main names no web plugin or web-specific symbol"
      (check (file-hits "tuna/main.ss" (term-index '("web"))) => [])
      (check (phrase-at? '("web") '(("web" . 1))) => #t))))
