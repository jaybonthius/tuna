;;; Inline completion engine. Matching sees plain text/indices, never buffers
;;; or candidate values; the post-command hook finishes it before redisplay.
prelude: :gerbil/core

(import :std/interface (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel :tuna/services/commands :tuna/services/keys
        :tuna/services/buffers :tuna/services/minibuffer :tuna/services/settings
        :tuna/services/completion)
(export completion-engine-plugin completion-styles completion-category-overrides
        completion-pipeline substring-compile)

(defsetting completion-styles '(substring) "Matching styles, tried in order until one matches.")
(defsetting completion-category-overrides [] "Category-to-style-list overrides, as an association list.")

(def (substring-compile (input : :string)) => :procedure
  (let* ((sensitive? (ormap char-upper-case? (string->list input)))
         (needle (if sensitive? input (string-downcase input))))
    (lambda ((text : :string))
      (if (string-empty? input) []
        (let (start (string-contains (if sensitive? text (string-downcase text)) needle))
          (and start [(cons start (fx+ start (string-length input)))]))))))

;; TEXTS is a vector, HISTORY newest-first text, COMPILERS pure styles.
;; Return (index . spans) rows. The first style with matches wins. SORTER,
;; when supplied, reorders plain (index . text) rows, never candidate values.
(def (completion-pipeline (texts : :vector) (input : :string) (history : :list)
                          (compilers : :list) (sorter :? :procedure := #f)) => :list
  (let* ((ranks (make-hash-table))
         (missing (length history))
         (matches
          (let styles ((rest compilers))
            (if (null? rest) []
              (let* ((matcher ((car rest) input))
                     (rows (let lp ((i 0) (out []))
                             (if (fx= i (vector-length texts)) (reverse out)
                               (let (spans (matcher (vector-ref texts i)))
                                 (lp (fx1+ i) (if spans (cons (cons i spans) out) out)))))))
                (if (pair? rows) rows (styles (cdr rest))))))))
    (let lp ((rest history) (i 0))
      (unless (null? rest)
        (unless (hash-key? ranks (car rest)) (hash-put! ranks (car rest) i))
        (lp (cdr rest) (fx1+ i))))
    (if sorter
      (let (spans (make-hash-table-eqv))
        (for-each (lambda (row) (hash-put! spans (car row) (cdr row))) matches)
        (map (lambda (row) (cons (car row) (hash-ref spans (car row))))
             (sorter (map (lambda (row) (cons (car row) (vector-ref texts (car row)))) matches))))
      (list-sort
        (lambda ((a : :pair) (b : :pair))
          (let* ((x (vector-ref texts (car a))) (y (vector-ref texts (car b)))
                 (rx (hash-ref ranks x missing)) (ry (hash-ref ranks y missing)))
            (cond ((not (fx= rx ry)) (fx< rx ry))
                  ((not (fx= (string-length x) (string-length y)))
                   (fx< (string-length x) (string-length y)))
                  ((equal? x y) (fx< (car a) (car b)))
                  (else (string<? x y)))))
        matches))))

(defclass completion-engine ((ctx : context) (sessions : :list) (styles : entry-table) (annotators : entry-table)
                            (keymap : entry-table)) final: #t)
(defclass completion-session ((owner : completion-engine) (table : completion-table)
                             (prompt : Prompt) (input : :string) (candidates : :list)
                             (selected :? candidate) (spans : HashTable)
                             (origin-command :? :symbol) (origin-buffer : buffer) (origin-view : view)
                             (revision : :fixnum) (require-match : :boolean) (default :? :string)
                             (history : :list) (style-names : :list)
                             (accepting? : :boolean) (ui : :t) (drawn-revision : :fixnum)) final: #t)

(def (session-here (self : completion-engine)) => completion-session
  (let (s (find (lambda ((s : completion-session)) (eq? (prompt-buffer s.prompt) (current-buffer))) self.sessions))
    (unless (and s (eq? s (car self.sessions))) (error "Not in the innermost completion prompt"))
    s))

(def (style-compilers (s : completion-session)) => :list
  (let (found (filter-map (lambda (name)
                           (let (e (entry-table-ref (completion-engine-styles s.owner) name))
                             (and e (completion-style-compile (entry-value e)))))
                         s.style-names))
    (if (null? found) [substring-compile] found)))

(def (recompute! (s : completion-session)) => :void
  (let* ((input (prompt-input s.prompt)) (table s.table)
         (items (completion-table-items table))
         (all (list->vector (if (procedure? items) (items input) items)))
         (rows (completion-pipeline (vector-map candidate-text all) input s.history (style-compilers s)
                                    (completion-table-sort table)))
         (ordered (map (lambda (row) (vector-ref all (car row))) rows))
         (previous s.selected))
    (set! s.input input)
    (set! s.candidates ordered)
    (hash-clear! s.spans)
    (for-each (lambda (row) (hash-put! s.spans (vector-ref all (car row)) (cdr row))) rows)
    (set! s.selected (or (and previous
                             (find (lambda ((c : candidate)) (equal? c.key (candidate-key previous))) ordered))
                        (and (pair? ordered) (car ordered))))
    (set! s.revision (fx1+ s.revision))))

(def (present! (s : completion-session)) => :void
  (let (ui (service-provider completion-ui-service))
    (when (or (not (eq? ui s.ui)) (not (fx= s.revision s.drawn-revision)))
      (when ui
        (call-with-service-provider completion-ui-service
          (lambda (provider) (CompletionUI-present (CompletionUI provider) (CompletionSession s) s.prompt))))
      (set! s.ui ui)
      (set! s.drawn-revision s.revision))))

(def (refresh! (s : completion-session)) => :void
  (unless (equal? s.input (prompt-input s.prompt)) (recompute! s))
  (present! s))

(def (exact-candidate (s : completion-session) (input : :string)) => (Maybe candidate)
  (let (text (if (and (string-empty? input) s.default) s.default input))
    (find (lambda ((c : candidate)) (equal? c.text text)) s.candidates)))

(def (exit-session! (s : completion-session) (use-input? : :boolean)) => :void
  (unless (eq? s (session-here s.owner)) (error "Not in the active completion prompt"))
  ;; RET may be the first command after a programmatic edit of the input.
  (refresh! s)
  (let* ((input s.input)
         (chosen (if use-input? (exact-candidate s input) s.selected)))
    (cond
     ((and use-input? (not s.require-match))
      (set! s.accepting? #t)
      (unwind-protect (prompt-exit! s.prompt input) (set! s.accepting? #f)))
     (chosen
      (set! s.accepting? #t)
      (unwind-protect
        (prompt-exit! s.prompt chosen history-text: (candidate-text chosen))
        (set! s.accepting? #f)))
     (s.require-match (message "Input does not name a candidate"))
     (else (prompt-exit! s.prompt input)))))

;; Annotators are read-only. A temporary selected-view snapshot supplies the
;; origin buffer without changing the layout's focus memory or showing it.
(def (annotate-visible (s : completion-session) (c : candidate)) => :list
  (let ((before (selected-view))
        (entries (entry-table-entries (completion-engine-annotators s.owner)
                                      (or (candidate-category c) (completion-table-category s.table)))))
    (unwind-protect
      (begin
        (set-selected-view! s.origin-view)
        (or (let lp ((rest entries))
              (and (pair? rest) (or ((entry-value (car rest)) c) (lp (cdr rest)))))
            (let (fallback (completion-table-annotate s.table)) (and fallback (fallback c)))
            []))
      (set-selected-view! before))))

(implement CompletionSession completion-session
  (session-input (lambda (s) s.input))
  (session-category (lambda (s) (:- (completion-table-category s.table) :symbol)))
  (session-candidates (lambda (s) s.candidates))
  (session-selected (lambda (s) s.selected))
  (session-command (lambda (s) s.origin-command))
  (session-buffer (lambda (s) s.origin-buffer))
  (session-revision (lambda (s) s.revision))
  (session-select! (lambda (s index)
                     (unless (and (fx>= index 0) (fx< index (length s.candidates)))
                       (error "Completion index out of range" index))
                     (let (c (list-ref s.candidates index))
                       (unless (eq? c s.selected)
                         (set! s.selected c) (set! s.revision (fx1+ s.revision))))))
  (session-exit! (lambda (s use-input?)
                   (call-with-context (completion-engine-ctx s.owner)
                     (lambda () (exit-session! s use-input?)))))
  (session-insert! (lambda (s)
                     (unless (eq? s (session-here s.owner)) (error "Not in the active completion prompt"))
                     (when s.selected
                       (let* ((answer (prompt-answer-node s.prompt))
                              (t (text-node-content answer))
                              (input (candidate-text s.selected)))
                         (text-replace! t 1 (fx1+ (text-size t)) input)
                         (goto-char (fx1+ (string-length input)))))))
  (session-spans (lambda (s c) (:- (hash-ref s.spans c []) :list)))
  (session-annotations (lambda (s c) (annotate-visible s c)))
  (session-group (lambda (s c)
                   (let (group (completion-table-group s.table))
                     (if group (group c) (candidate-group c))))))

(def (ask! (self : completion-engine) (question : :string) (table : completion-table)
           (require-match : :boolean) (initial : :string) (history :? :symbol)
           (default :? :string)) => :t
  (let* ((origin (current-buffer)) (origin-view (copy-view (selected-view)))
         (command (this-command))
         (overrides (setting-value completion-category-overrides))
         (override (assq (completion-table-category table) overrides))
         (styles (if override (cdr override) (setting-value completion-styles)))
         (recent (if history (minibuffer-history history) []))
         (session #f))
    (unless (and (list? styles) (andmap symbol? styles)) (error "Completion styles must be a list of names" styles))
    (unwind-protect
      (let (answer
            (read-from-minibuffer question initial history: history
              setup: (lambda ((p : Prompt))
                       (set! session (completion-session owner: self table: table prompt: p input: initial
                         candidates: [] selected: #f spans: (make-hash-table-eq)
                         origin-command: command origin-buffer: origin origin-view: origin-view revision: 0
                         require-match: require-match default: default history: recent style-names: styles
                         accepting?: #f ui: #f drawn-revision: -1))
                       (set! self.sessions (cons session self.sessions))
                       (recompute! session)
                       (when default
                         (let (c (exact-candidate session ""))
                           (when c (set! (completion-session-selected session) c))))
                       (prompt-set-exit-check! p
                         (lambda ((input : :string))
                           (and require-match (not (completion-session-accepting? session))
                                (not (exact-candidate session input)) "Input does not name a candidate")))
                       (set-node-keymap! (prompt-answer-node p) self.keymap)
                       (present! session))))
        (cond ((candidate? answer) (candidate-value answer))
              ((and require-match (string? answer))
               (let (c (exact-candidate session answer)) (if c (candidate-value c) answer)))
              (else answer)))
      (when session (set! self.sessions (remq session self.sessions))))))

(implement Completion completion-engine
  (completing-read (lambda (self question table require-match initial history default)
                     (ask! self question table require-match initial history default)))
  (current-session (lambda (self)
                     (and (pair? self.sessions) (CompletionSession (car self.sessions)))))
  (styles (lambda (self) self.styles))
  (annotators (lambda (self) self.annotators)))

(defplugin (completion-engine-plugin ctx)
  "Completion reads with smart-case substring matching; works without a list UI."
  requires: [commands-service input-service buffers-service minibuffer-service settings-service]
  optional: [completion-service completion-ui-service messages-service]
  (let (self (completion-engine ctx: ctx sessions: [] styles: (new-entry-table) annotators: (new-entry-table)
                               keymap: (new-keymap)))
    (context-provide! ctx completion-service (Completion self))
    (keymap-set-in ctx (completion-engine-keymap self) "RET" 'completion-accept-input)
    (keymap-set-in ctx (completion-engine-keymap self) "M-RET" 'completion-accept-input)
    (context-define-completion-style! ctx
      (make-completion-style 'substring substring-compile "Smart-case substring matching."))
    (context-define-command! ctx 'completion-accept-input
      (lambda () (exit-session! (session-here self) #t))
      doc: "Accept exactly the input typed, validating required matches."
      visible?: (lambda (c origin) #f))
    (context-add-hook! ctx service-changed-hook 'completion-ui
      (lambda (svc outgoing incoming)
        (when (eq? svc completion-ui-service)
          (for-each (lambda ((s : completion-session)) (set! s.drawn-revision -1))
                    (completion-engine-sessions self))
          (when (pair? (completion-engine-sessions self))
            (refresh! (car (completion-engine-sessions self)))))))
    (context-add-hook! ctx post-command-hook 'completion
      (lambda ()
        (when (pair? (completion-engine-sessions self))
          (refresh! (car (completion-engine-sessions self))))))))
