# Contract sketch (illustrative, not compiled)

Supporting file for [README.md](README.md), question 3. This is the shape of
the proposed contracts, written in the repository's style
(`tuna/services/minibuffer.ss`, `tuna/services/keys.ss`) so the owner and an
implementer can judge it. **It has not been compiled or checked with the
Gerbil MCP tools**; names, types and signatures are proposals.

## `tuna/services/commands.ss` (split out of `keys.ss`)

```scheme
;; A named action. Today `command` lives in the keys contract
;; (tuna/services/keys.ss:141-145); it moves here unchanged plus two fields.
(defstruct command ((name      : :symbol)
                    (procedure : :procedure)        ; thunk, run as a task
                    (doc       : :string)
                    (visible?  : :procedure)        ; command, origin buffer -> boolean (Emacs completion-predicate)
                    (modes     : :list))            ; empty: everywhere (Emacs command-modes)
  final: #t)

(interface Commands
  (define-command! (ctx : context) (c : command) (source : :t)) => :void
  (command-entry (name : :symbol)) => :t            ; entry with provenance, or #f
  (command-names) => :list                          ; every effective command name
  ;; Run NAME as if its keys had been typed: it becomes this-command, and
  ;; last-command afterwards (Emacs command-execute with 'record).
  (call-command (name : :symbol)) => :void)
```

The keys contract keeps bindings and gains the reverse lookup M-x needs:

```scheme
  ;; Keys bound to the command NAME in the keymaps active at FOCUS, shortest
  ;; first (Emacs where-is-internal).
  (where-is (name : :symbol) (focus :? node)) => :list
```

## `tuna/services/completion.ss`

```scheme
;; One thing to choose. TEXT is matched and shown; VALUE is what
;; completing-read returns. KEY identifies it across updates (the selection
;; stays on it while typing) and defaults to TEXT. CATEGORY overrides the
;; table's, for multi-source reads.
(defstruct candidate ((text     : :string)
                      (value    : :t)
                      (key      : :t)
                      (category :? :symbol)
                      (group    :? :string))
  final: #t)

;; What to complete from. ITEMS is a list of candidates, or a procedure of
;; the input returning one (dynamic), or an async-source.
(defstruct completion-table ((category      : :symbol)
                             (items         : :t)
                             (sort          :? :procedure)   ; #f: engine default; identity: keep order
                             (group         :? :procedure)   ; candidate -> title
                             (annotate      :? :procedure)   ; fallback when no annotator is registered
                             (preview       :? :procedure)   ; state procedure, see below
                             (narrow        : :list))        ; ((char . "Buffers") ...)
  final: #t)

;; Preview protocol (Consult's state function, consult.el:1855-1890):
;;   (preview 'setup #f) (preview 'preview cand-or-#f) ... (preview 'exit #f)
;;   (preview 'return cand-or-#f)

;; A matching style (Emacs completion-styles-alist entry). COMPILE turns the
;; input into a matcher: candidate text -> #f, or a list of matched spans
;; (start . end) for highlighting. Spans are computed only for shown rows.
(defstruct completion-style ((name    : :symbol)
                             (compile : :procedure)          ; input -> matcher
                             (doc     : :string))
  final: #t)

;; An annotation: fields drawn in columns, not a padded string.
(defstruct annotation-field ((text  : :string)
                             (class : :symbol))              ; key, doc, size, date ...
  final: #t)

(interface Completion                                        ; the engine
  ;; Ask, and return the chosen candidate's value (or the typed text when
  ;; REQUIRE-MATCH is #f). A yield point.
  (completing-read (prompt : :string) (table : completion-table)
                   (require-match : :boolean) (initial : :string)
                   (history :? :symbol) (default :? :t)) => :t
  ;; The innermost running session, or #f.
  (current-session) => :t
  ;; Registries, each an entry-table of owner-tagged entries (ADR 2).
  (styles) => entry-table                                    ; name -> completion-style
  (annotators) => entry-table)                               ; category -> procedure

;; What a UI (or Embark-like or preview code) may ask of a session.
(interface CompletionSession
  (session-input) => :string
  (session-category) => :symbol
  (session-candidates) => :vector       ; filtered, sorted, grouped
  (session-selected) => :t              ; candidate or #f (the prompt itself)
  (session-select! (index : :fixnum)) => :void
  (session-exit! (use-input? : :boolean)) => :void
  (session-command) => :t               ; the command that started it
  (session-revision) => :fixnum)        ; changes whenever candidates or selection change

(interface CompletionUI                                      ; the vertico slot
  ;; Present SESSION in PROMPT's buffer: add its nodes and keymap there.
  (present (session : CompletionSession) (prompt : :t)) => :void)

(def completion-service    (new-service 'completion is-Completion? tier: 'live))
(def completion-ui-service (new-service 'completion-ui is-CompletionUI? tier: 'live))

(def session-started-hook (new-hook 'completion-session-started))
(def session-finished-hook (new-hook 'completion-session-finished)) ; vertico-repeat, savehist-like uses
```

## What a package author writes

The M-x plugin, roughly (this is the brief's "code sample from a package
author's point of view"):

```scheme
(defplugin (extended-command-plugin ctx)
  "M-x: run a command by name."
  requires: [commands-service completion-service]
  (defcommand (execute-extended-command) "Read a command name, then run it."
    (let (name (completing-read "M-x "
                 (make-completion-table
                  category: 'command
                  items: (lambda (_input) (map command-candidate (visible-command-names)))
                  narrow: [])
                 require-match: #t history: 'extended-command))
      (call-command name)))
  (keymap-set "M-x" 'execute-extended-command))
```

and the annotations plugin registers, for category `command`:

```scheme
(context-define-annotator! ctx 'command
  (lambda (c)        ; c : candidate whose value is a command name
    [(make-annotation-field (keys-description (where-is (candidate-value c))) 'key)
     (make-annotation-field (first-line (command-doc (candidate-value c))) 'doc)]))
```
