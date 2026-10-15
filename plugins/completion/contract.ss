;;; Completion vocabulary and live slots (ADR 14). Values and identities
;;; stay explicit; only text and indices enter the matching pipeline.
prelude: :gerbil/core

(import :std/interface :tuna/kernel :tuna/plugins/buffers/contract :tuna/plugins/minibuffer/contract)
(export (struct-out candidate completion-table completion-style annotation-field)
        (interface-out Completion CompletionSession CompletionUI)
        completion-service completion-ui-service completing-read current-completion-session
        context-define-completion-style! context-define-annotator! strings->candidates)

;; KEY is explicit. Lists and records returned by a session are read-only.
(defstruct candidate ((text : :string) (value : :t) (key : :t)
                      (category :? :symbol := #f) (group :? :string := #f))
  final: #t)

;; ITEMS is a candidate list or input -> candidate list. SORT reorders plain
;; (index . text) pairs, initially in source order; #f uses history/length/name.
;; GROUP is candidate -> optional group title. Table callbacks are read-only.
(defstruct completion-table ((category : :symbol) (items : :t)
                             (sort :? :procedure := #f) (group :? :procedure := #f)
                             (annotate :? :procedure := #f))
  final: #t)

;; COMPILE: input -> (text -> #f or list of zero-based half-open spans).
;; An empty span list is a match, not a failure. Styles contain no live state.
(defstruct completion-style ((name : :symbol) (compile : :procedure) (doc : :string)) final: #t)
(defstruct annotation-field ((text : :string) (class : :symbol)) final: #t)

(interface CompletionSession
  (session-input) => :string
  (session-category) => :symbol
  (session-candidates) => :list
  (session-selected) => (Maybe candidate)
  (session-command) => (Maybe :symbol)
  (session-buffer) => buffer
  (session-revision) => :fixnum
  (session-select! (index : :fixnum)) => :void
  (session-exit! (use-input? : :boolean)) => :void
  (session-insert!) => :void
  ;; Called by a UI for shown candidates only; annotations run in the origin buffer.
  (session-spans (c : candidate)) => :list
  (session-annotations (c : candidate)) => :list
  (session-group (c : candidate)) => (Maybe :string))

(interface Completion
  (completing-read (question : :string) (table : completion-table)
                   (require-match : :boolean) (initial : :string)
                   (history :? :symbol) (default :? :string)) => :t
  (current-session) => (Maybe CompletionSession)
  (styles) => entry-table
  (annotators) => entry-table)

(interface CompletionUI
  ;; Idempotently rebuild presentation from SESSION in PROMPT's buffer.
  ;; The engine calls on creation, revision changes and provider replacement.
  ;; A provider owns its nodes and key receipts and removes them on deactivation.
  (present (session : CompletionSession) (prompt : Prompt)) => :void)

(def completion-service (new-service 'completion is-Completion? tier: 'live
  doc: "Completion reads, sessions, matching styles and annotators."))
(def completion-ui-service (new-service 'completion-ui is-CompletionUI? tier: 'live
  doc: "Presents a completion session in its prompt buffer."))

(def (completing-read (question : :string) (table : completion-table)
                      require-match: (require-match : :boolean := #t)
                      initial: (initial : :string := "")
                      history: (history :? :symbol := #f)
                      default: (default :? :string := #f)) => :t
  (with-service-provider (provider completion-service Completion) (Completion-completing-read provider question table require-match initial history default)))

(def (current-completion-session) => (Maybe CompletionSession)
  (:? (let (provider (service-provider completion-service))
          (and provider (Completion-current-session (Completion provider)))) CompletionSession))

(def (context-define-completion-style! (ctx : context) (style : completion-style)
                                       priority: (priority : :fixnum := 0)) => :void
  (:- (with-service-provider (provider completion-service Completion)
    (context-add-entry! ctx (Completion-styles provider) (completion-style-name style) style
                        priority: priority doc: (completion-style-doc style))) :void))

;; An annotator may return #f to decline, or a field list (including []).
(def (context-define-annotator! (ctx : context) (category : :symbol) (annotate : :procedure)
                               priority: (priority : :fixnum := 0)) => :void
  (:- (with-service-provider (provider completion-service Completion) (context-add-entry! ctx (Completion-annotators provider) category annotate priority: priority)) :void))

(def (strings->candidates (strings : :list)) => :list
  (map (lambda ((text : :string)) (make-candidate text: text value: text key: text)) strings))
