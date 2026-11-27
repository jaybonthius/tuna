(import (tuna) (test) (modes) (buffers) (hooks) (tables) (completion) (completion rows) (completion-list) (completion-popup) (diagnostics-list)
        (docs-at-point-display) (echo-area) (dired) (help) (jsonrpc) (minibuffer) (occur) (pi-chat) (runs) (shell-commands)
        (terminal) (ui) (lsp) (syntax-highlighting) (rainbow-delimiters) (diagnostics) (docs-at-point) (editing))

(test "the plugins whose major modes serve only their own buffers mark them plugin-only"
  (for-each
    (lambda (mode) (check-equal? (list mode #t) (list mode (tables:ref modes:plugin-only mode #f))))
    (list completion/rows:mode completion-list:mode completion-popup:mode diagnostics-list:mode docs-at-point-display:docs-mode
          echo-area:messages-mode dired:mode help:mode jsonrpc:events-mode minibuffer:mode occur:mode occur:edit-mode pi-chat:mode
          runs:mode shell-commands:compilation-mode terminal:mode ui:showcase-mode)))

(tables:define-table derived-keymap)

(hooks:define-hook derived-hook)

(modes:define-major-mode derived (parent help:mode) (keymap derived-keymap) (hook derived-hook))

(test "a mode derived from a plugin-only mode is not plugin-only unless it is marked too"
  (let ([b (buffers:make "derived" "x")])
    (check-equal? #f (tables:ref modes:plugin-only derived #f))
    (modes:switch-major-mode derived b)
    (check-equal? derived (modes:major-mode b))))

(test "plugins define their minor modes with the form, so each is named; state modes keep their depths, lighters and keymaps"
  (check-equal? '(terminal:copy-mode? terminal:char-mode? terminal:semi-char-mode? minibuffer:y-or-n-mode lsp:managed? dired:hide-details?
                  syntax-highlighting:mode rainbow-delimiters:mode diagnostics:mode docs-at-point:mode editing:electric-indent)
                (map modes:name (list terminal:copy-mode? terminal:char-mode? terminal:semi-char-mode? minibuffer:y-or-n-mode lsp:managed?
                                      dired:hide-details? syntax-highlighting:mode rainbow-delimiters:mode diagnostics:mode
                                      docs-at-point:mode editing:electric-indent)))
  (check-equal? '((-30 "Copy") (-20 "Char") (-10 #f))
                (map (lambda (m) (list (tables:ref modes:minor-modes m #f) (modes:lighter m)))
                     (list terminal:copy-mode? terminal:char-mode? terminal:semi-char-mode?)))
  (check-equal? '(#f #f "Whether a language server manages the buffer, or the current buffer when none is given." 0 #t)
                (list (lsp:managed?) (lsp:managed? (buffers:make "unmanaged" "")) (definition-documentation lsp:managed?)
                      (tables:ref modes:minor-modes lsp:managed? #f) (eq? lsp:keymap (tables:ref modes:keymaps lsp:managed? #f))))
  (check-equal? (list dired:mode) (tables:ref modes:minor-mode-majors dired:hide-details? #f)))

(test "the names and marks are the defining modules' entries, so they stay through a reload of modes"
  (reload-modules! '((modes)))
  (check-equal? (list 'lsp:managed? #t (list dired:mode))
                (list (modes:name lsp:managed?) (tables:ref modes:plugin-only help:mode #f) (tables:ref modes:minor-mode-majors dired:hide-details? #f))))
