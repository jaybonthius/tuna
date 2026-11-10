(import (tuna) (tuna plugins))
;; 2 :ensure, and 3 :config: forms after the import
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
;; 1 setq
(set-option! gptel/org:branching-context #t)
;; 4 :custom
(set-option! compile-angel:verbose #f)
;; 6 :hook
(recentf:mode #t)
(add-hook! prog:mode-hook corfu:mode)
;; 7 :bind
(keys:bind! keys:global "C-x m" ghostel:ghostel)
;; 8 defun
(define (browse-file-remote) "browsing")
;; 9 add-hook
(define exported '())
(define (calendar-export-after-save path) (set! exported (cons path exported)))
(add-hook! files:after-save calendar-export-after-save)
;; 10 interactive: a command defined by a plugin's macro
(commands:define-command (open-notes) "notes")
;; 11 add-to-list, push
(table-set! compile-angel:excluded "/init.el")
;; 12 setq-default
(set-option! line-numbers:width 3)
;; 13 defvar, defconst
(define theme-state-file "~/.local/state/theme")
;; 14 :init, read when used
(set-option! hel:want-minibuffer #f)
;; 15 :mode
(table-set! files:modes "go" go-ts:mode)
;; 16 with-eval-after-load
(keys:bind! org/mouse:keymap "<mouse-1>" org:open-at-mouse)
;; 17 setq-local, kill-local-variable
(add-hook! prog:mode-hook
  (lambda ()
    (set-option-local! corfu:auto #t corfu:auto-delay 0.1 corfu:auto-prefix 2)
    (remove-option-local! symbols-outline:fetch-fn)))
;; 18 require, load: (project) above; a module of the user's own, under lib/
(import (gui-presentation))
;; 19 global-set-key, define-key, keymap-unset
(keys:bind! keys:global "C-c g o" browse-file-remote)
(keys:unbind! geiser/mode:keymap "M-.")
;; 20 advice-add, define-advice
(set! prompts:yes-or-no? prompts:y-or-n?)
(define agenda-refreshes 0)
(define (refresh-agenda-files) (set! agenda-refreshes (+ agenda-refreshes 1)))
(advice-add! org/agenda:agenda
  (lambda (agenda . args) (refresh-agenda-files) (apply agenda args)))
;; :if
(when (file-exists? "/bin/sh")
  (when-installed (vertico)
    (set-option! vertico:count 15)))
