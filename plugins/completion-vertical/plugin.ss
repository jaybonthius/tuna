#lang :tuna/prelude
;;; Vertical completion presentation. Nodes are rebuilt from the session;
;;; the renderer still sends one whole-screen morph. No client list state.
(import :tuna/plugins/commands/contract
        :std/interface (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel :tuna/plugins/keys/contract :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract :tuna/plugins/minibuffer/contract :tuna/plugins/settings/contract
        :tuna/plugins/completion/contract :tuna/plugins/stylesheets/contract)
(export completion-vertical completion-count)

(defsetting completion-count 10 "Maximum visible completion rows; a positive integer.")
(def row-keymap (new-keymap))

(defclass vertical-display ((prompt : Prompt) (session : CompletionSession)
                           (counter : node) (list : node) (answer : node)
                           (previous-map :? entry-table)) final: #t)
(defclass vertical-ui ((displays : HashTable) (keymap : entry-table)) final: #t)

(def (selection-index (s : CompletionSession)) => :fixnum
  (let lp ((rest (CompletionSession-session-candidates s)) (i 0))
    (cond ((null? rest) -1)
          ((eq? (car rest) (CompletionSession-session-selected s)) i)
          (else (lp (cdr rest) (fx1+ i))))))

(def (navigate! (delta : :fixnum) (edge :? :symbol)) => :void
  (let* ((s (current-completion-session)) (size (length (CompletionSession-session-candidates s))))
    (when (fxpositive? size)
      (CompletionSession-session-select! s
        (case edge ((first) 0) ((last) (fx1- size))
          (else (fxmax 0 (fxmin (fx1- size) (fx+ (selection-index s) delta)))))))))

;; Merge overlapping spans through a character mask, for styles with several
;; components. HTML is built only for shown rows; zero-based spans are data.
(def (highlighted-text (text : :string) (spans : :list)) => :list
  (let* ((size (string-length text)) (marked (make-vector size #f)))
    (for-each (lambda ((span : :pair))
                (let lp ((i (fxmax 0 (car span))))
                  (when (fx< i (fxmin size (cdr span)))
                    (vector-set! marked i #t) (lp (fx1+ i))))) spans)
    (let lp ((i 0) (out []))
      (if (fx= i size) (reverse out)
        (let* ((mark? (vector-ref marked i))
               (end (let run ((j (fx1+ i)))
                      (if (and (fx< j size) (eq? mark? (vector-ref marked j))) (run (fx1+ j)) j)))
               (part (substring text i end)))
          (lp end (cons (if mark? `(mark ,part) part) out)))))))

(def (draw-row (n : node) (children : :list)) => :list
  (let* ((c (node-attribute n 'candidate)) (selected? (node-attribute n 'selected?)))
    `(li (@ (class "completion-item"))
         (button (@ (type "button") (tabindex "-1")
                    (class "completion-row") (aria-current ,(if selected? "true" "false")))
           (span (@ (class "completion-label"))
                 ,@(highlighted-text (candidate-text c) (node-attribute n 'spans)))
           ,@(map (lambda ((field : annotation-field))
                    `(span (@ (class ,(string-append "completion-field completion-"
                                                    (symbol->string field.class)))) ,field.text))
                  (node-attribute n 'annotations))))))

(def (remove-display! (self : vertical-ui) (d : vertical-display)) => :void
  (let* ((b (prompt-buffer d.prompt)) (root (buffer-root b)))
    (when (memq b (buffer-list))
      (set-node-children! root (filter (lambda (n) (and (not (eq? n d.counter)) (not (eq? n d.list))))
                                      (node-children root)))
      (when (eq? (node-keymap d.answer) self.keymap)
        (set-node-keymap! d.answer d.previous-map)))))

(def (present-vertical! (self : vertical-ui) (s : CompletionSession) (p : Prompt)) => :void
  (let* ((b (prompt-buffer p)) (root (buffer-root b))
         (d (or (hash-get self.displays b)
                (let* ((children (node-children root))
                       (answer (prompt-answer-node p))
                       (counter (new-node 'completion-counter))
                       (list (new-node 'completion-list))
                       (fresh (vertical-display prompt: p session: s counter: counter list: list
                                  answer: answer previous-map: (node-keymap answer))))
                  (set-node-keymap! answer self.keymap)
                  (set-node-children! root (append [counter] children [list]))
                  (hash-put! self.displays b fresh)
                  fresh)))
         (candidates (CompletionSession-session-candidates s))
         (size (length candidates)) (index (selection-index s))
         (count (setting-value completion-count)))
    (unless (and (fixnum? count) (fxpositive? count)) (error "Completion count must be positive" count))
    (set-node-attribute! (vertical-display-counter d) 'content
      (string-append (number->string (fx1+ index)) "/" (number->string size)))
    (let ((start (fxmax 0 (fxmin (fxmax 0 (fx- size count)) (fx- index (quotient count 2)))))
          (selected (CompletionSession-session-selected s)))
      (set-node-children! (vertical-display-list d)
        (let lp ((rest (list-tail candidates start)) (i start) (left count) (group #f) (out []))
          (if (or (null? rest) (fxzero? left)) (reverse out)
            (let* ((c (car rest)) (title (CompletionSession-session-group s c))
                   (heading (and title (not (equal? title group))
                                 (new-node 'completion-group attributes: [['content . title]])))
                   (row (new-node 'completion-row keymap: row-keymap
                          attributes: [['candidate . c] ['session . s] ['index . i]
                                       (cons 'selected? (eq? selected c))
                                       (cons 'spans (CompletionSession-session-spans s c))
                                       (cons 'annotations (CompletionSession-session-annotations s c))])))
              (lp (cdr rest) (fx1+ i) (fx1- left) title
                  (cons row (if heading (cons heading out) out))))))))))

(implement CompletionUI vertical-ui
  (present (lambda (self s p) (present-vertical! self s p))))

(defplugin (completion-vertical ctx)
  "A vertical completion list with keyboard navigation and clickable rows."
  provides: [completion-ui-service]
  requires: [commands-service completion-service input-service buffers-service settings-service layout-service minibuffer-service]
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules "rules.css")
  (for-each (lambda (kind) (context-define-node-kind! ctx kind))
            '(completion-counter completion-list completion-row completion-group))
  (context-define-node-renderer! ctx 'completion-counter
    (lambda (n children) `(span (@ (class "completion-counter") (aria-label "Selection index"))
                               ,(node-attribute n 'content))))
  (context-define-node-renderer! ctx 'completion-list
    (lambda (n children) `(ul (@ (class "completion-list") (aria-label "Completions")) ,@children)))
  (context-define-node-renderer! ctx 'completion-group
    (lambda (n children) `(li (@ (class "completion-group")) ,(node-attribute n 'content))))
  (context-define-node-renderer! ctx 'completion-row draw-row)
  (let (self (vertical-ui displays: (make-hash-table-eq) keymap: (new-keymap)))
    (for-each (lambda (definition)
                (context-define-command! ctx (car definition) (cdr definition)
                  visible?: (lambda (c origin) #f)))
      [(cons 'completion-next (lambda () (navigate! 1 #f)))
       (cons 'completion-previous (lambda () (navigate! -1 #f)))
       (cons 'completion-first (lambda () (navigate! 0 'first)))
       (cons 'completion-last (lambda () (navigate! 0 'last)))
       (cons 'completion-select (lambda () (CompletionSession-session-exit! (current-completion-session) #f)))
       (cons 'completion-insert (lambda () (CompletionSession-session-insert! (current-completion-session))))])
    (for-each (lambda (binding) (keymap-set-in ctx (vertical-ui-keymap self) (car binding) (cdr binding)))
      '(("C-n" . completion-next) ("<down>" . completion-next)
        ("C-p" . completion-previous) ("<up>" . completion-previous)
        ("M-<" . completion-first) ("M->" . completion-last)
        ("RET" . completion-select) ("M-RET" . completion-accept-input) ("TAB" . completion-insert)))
    (context-define-command! ctx 'completion-click
      (lambda ()
        (let* ((pos (event-start (last-command-event))) (n (and pos (posn-node pos))))
          (if (and n (eq? (node-kind n) 'completion-row))
            (let (s (node-attribute n 'session))
              (select-view (posn-view pos))
              (CompletionSession-session-select! s (node-attribute n 'index))
              (CompletionSession-session-exit! s #f))
            (when pos (report-stale-click pos what: "completion row")))))
      visible?: (lambda (c origin) #f))
    (keymap-set-in ctx row-keymap "<mouse-1>" 'completion-click)
    (context-add-hook! ctx kill-buffer-hook 'completion-vertical
      (lambda (b) (hash-remove! (vertical-ui-displays self) b)))
    (let ((provider (CompletionUI self))
          (clear! (lambda ()
                    (hash-for-each (lambda (b d) (remove-display! self d)) (vertical-ui-displays self))
                    (hash-clear! (vertical-ui-displays self)))))
      (context-add-hook! ctx service-changed-hook 'completion-vertical
        (lambda (svc outgoing incoming)
          (when (and (eq? svc completion-ui-service) (eq? outgoing provider)) (clear!)))
        depth: -10)
      (context-defer! ctx clear!)
      (context-provide! ctx completion-ui-service provider))))
