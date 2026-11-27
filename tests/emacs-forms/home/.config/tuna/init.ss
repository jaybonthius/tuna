(import (hooks) (options) (tables) (saved))
(import (tuna))
;; :ensure, and :config: forms after the import
(use-plugin vertico (git "https://github.com/minad/vertico"))
(use-plugin gptel)
(use-plugin compile-angel)
(use-plugin recentf)
(use-plugin prog)
(use-plugin corfu)
(use-plugin keys)
(use-plugin ghostel)
(use-plugin files)
(use-plugin auto-mode)
(use-plugin commands)
(use-plugin line-numbers)
(use-plugin hel)
(use-plugin go-ts)
(use-plugin org)
(use-plugin symbols-outline)
(use-plugin project)
(use-plugin geiser)
(use-plugin prompts)
(use-plugin buffers-stub)
;; setq
(options:set! gptel/org:branching-context #t)
;; :custom
(options:set! compile-angel:verbose #f)
;; :hook
(recentf:mode #t)
(hooks:add! prog:mode-hook corfu:mode)
;; :bind
(keys:bind! keys:global "C-x m" ghostel:ghostel)
;; defun
(define (browse-file-remote) "browsing")
;; add-hook
(define exported '())
(define (calendar-export-after-save path) (set! exported (cons path exported)))
(hooks:add! files:after-save calendar-export-after-save)
;; interactive: a command defined by a plugin's macro
(commands:define-command (open-notes) "notes")
;; add-to-list, push
(tables:set! compile-angel:excluded "/init.el")
;; setq-default
(options:set! line-numbers:width 3)
;; defvar, defconst
(define theme-state-file "~/.local/state/theme")
;; :init, read when used
(options:set! hel:want-minibuffer #f)
;; :mode
(tables:set! auto-mode:file-names "go" go-ts:mode)
;; with-eval-after-load
(keys:bind! org/mouse:keymap "<mouse-1>" org:open-at-mouse)
;; setq-local, kill-local-variable
(hooks:add! prog:mode-hook
  (lambda ()
    (options:set-local! corfu:auto #t corfu:auto-delay 0.1 corfu:auto-prefix 2)
    (options:unset-local! symbols-outline:fetch-fn)))
;; require, load: (project) above; a module of the user's own, under lib/
(import (gui-presentation))
;; global-set-key, define-key, keymap-unset
(keys:bind! keys:global "C-c g o" browse-file-remote)
(keys:unbind! geiser/mode:keymap "M-.")
;; advice-add, define-advice
(define prompts:yes-or-no? prompts:y-or-n?)
(define agenda-refreshes 0)
(define (refresh-agenda-files) (set! agenda-refreshes (+ agenda-refreshes 1)))
(advice-add! org/agenda:agenda
  (lambda (agenda . args) (refresh-agenda-files) (apply agenda args)))
;; :if
(when (file-exists? "/bin/sh")
  (options:set! vertico:count 15))
;; savehist-additional-variables
(saved:define-saved search-ring '() list?)
(import (console))
