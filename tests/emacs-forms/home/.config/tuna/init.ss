(import (tuna) (tuna plugins))
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
(set-option! gptel/org:branching-context #t)
;; :custom
(set-option! compile-angel:verbose #f)
;; :hook
(recentf:mode #t)
(add-hook! prog:mode-hook corfu:mode)
;; :bind
(keys:bind! keys:global "C-x m" ghostel:ghostel)
;; defun
(define (browse-file-remote) "browsing")
;; add-hook
(define exported '())
(define (calendar-export-after-save path) (set! exported (cons path exported)))
(add-hook! files:after-save calendar-export-after-save)
;; interactive: a command defined by a plugin's macro
(commands:define-command (open-notes) "notes")
;; add-to-list, push
(table-set! compile-angel:excluded "/init.el")
;; setq-default
(set-option! line-numbers:width 3)
;; defvar, defconst
(define theme-state-file "~/.local/state/theme")
;; :init, read when used
(set-option! hel:want-minibuffer #f)
;; :mode
(table-set! files:modes "go" go-ts:mode)
;; with-eval-after-load
(keys:bind! org/mouse:keymap "<mouse-1>" org:open-at-mouse)
;; setq-local, kill-local-variable
(add-hook! prog:mode-hook
  (lambda ()
    (set-option-local! corfu:auto #t corfu:auto-delay 0.1 corfu:auto-prefix 2)
    (remove-option-local! symbols-outline:fetch-fn)))
;; require, load: (project) above; a module of the user's own, under lib/
(import (gui-presentation))
;; global-set-key, define-key, keymap-unset
(keys:bind! keys:global "C-c g o" browse-file-remote)
(keys:unbind! geiser/mode:keymap "M-.")
;; advice-add, define-advice
(set! prompts:yes-or-no? prompts:y-or-n?)
(define agenda-refreshes 0)
(define (refresh-agenda-files) (set! agenda-refreshes (+ agenda-refreshes 1)))
(advice-add! org/agenda:agenda
  (lambda (agenda . args) (refresh-agenda-files) (apply agenda args)))
;; :if
(when (file-exists? "/bin/sh")
  (when-installed (vertico)
    (set-option! vertico:count 15)))
;; savehist-additional-variables
(define-saved search-ring '() list?)
