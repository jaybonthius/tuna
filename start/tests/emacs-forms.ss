(import (tuna) (test) (plugins) (fixtures) (remotes))

(define stubs
  '((auto-mode ((auto-mode) (import (tables)) (tables:define-table file-names)))
    (buffers-stub ((buffers-stub) (import (scopes)) (define (enter!) (scopes:current (scopes:make)))))
    (commands ((commands)
               (import (tables))
               (tables:define-table all)
               (define-syntax define-command
                 (syntax-rules ()
                   [(_ (name . formals) body ...)
                    (begin
                      (define-public (name . formals) body ...)
                      (define-values () (begin (tables:set! all 'name name) (values))))]))))
    (compile-angel ((compile-angel) (import (options) (tables)) (options:define-option verbose #t boolean?) (tables:define-table excluded)))
    (corfu ((corfu)
            (import (options))
            (options:define-option auto #f boolean?)
            (options:define-option auto-delay 0.2 real?)
            (options:define-option auto-prefix 3 fixnum?)
            (define (mode) 'corfu)))
    (files ((files)
            (import (hooks))
            (hooks:define-hook after-save "Called with the path of each file saved.")
            (define (save! path) (after-save path) path)))
    (fill ((fill) (import (options)) (options:define-option column 70 fixnum?)))
    (geiser ((geiser) (import (geiser mode)) (define (version) 1))
            ((geiser mode) (import (tables)) (tables:define-table keymap) (tables:set! keymap "M-." 'geiser-edit-symbol-at-point)))
    (ghostel ((ghostel) (define (ghostel) 'terminal)))
    (go-ts ((go-ts) (define (mode) 'go)))
    (gptel ((gptel) (import (gptel org)) (define (send) 'sent))
           ((gptel org) (import (options)) (options:define-option branching-context #f boolean?)))
    (hel ((hel) (import (options)) (options:define-option want-minibuffer #t boolean?) (define (minibuffer?) (want-minibuffer))))
    (keys ((keys)
           (import (tables))
           (tables:define-table global)
           (define (bind! keymap key command) (tables:set! keymap key command))
           (define (unbind! keymap key) (tables:remove! keymap key))))
    (line-numbers ((line-numbers) (import (options)) (options:define-option width 2 fixnum?)))
    (org ((org) (import (org mouse) (org agenda)) (define (open-at-mouse) 'opened))
         ((org agenda) (define (agenda . arguments) (cons 'agenda arguments)))
         ((org mouse) (import (tables)) (tables:define-table keymap)))
    (prog ((prog) (import (fill) (hooks) (options)) (hooks:define-hook mode-hook) (define (mode) (mode-hook)) (options:set! fill:column 90)))
    (project ((project) (define (root) "/home/groucho/src")))
    (prompts ((prompts) (define (yes-or-no? question) 'yes-or-no) (define (y-or-n? question) 'y-or-n)))
    (recentf ((recentf) (define %on #f) (define (mode enable?) (set! %on enable?) %on) (define (enabled?) %on)))
    (symbols-outline ((symbols-outline) (import (options)) (options:define-option fetch-fn #f (lambda (v) (or (not v) (procedure? v))))))))

(for-each
  (lambda (stub)
    (for-each
      (lambda (module) (fixtures:write-module! (fixtures:home-path "src" (symbol->string (car stub)) "src") (car module) (cdr module)))
      (cdr stub)))
  stubs)
(fixtures:write-lib-module! '(gui-presentation) '((import (fill) (options)) (define (start!) (options:set! fill:column 100) 'presenting)))

(define reports
  (fixtures:reports-during
    (lambda ()
      (fixtures:load-configuration!
        `((import (hooks) (options) (tables) (saved))
          (import (tuna))
          (use-plugin vertico (git ,(remotes:url "vertico")))
          ,@(map (lambda (stub) `(use-plugin ,(car stub) (local ,(string-append "~/src/" (symbol->string (car stub)))))) stubs)
          (options:set! gptel/org:branching-context #t)
          (options:set! compile-angel:verbose #f)
          (recentf:mode #t)
          (hooks:add! prog:mode-hook corfu:mode)
          (keys:bind! keys:global "C-x m" ghostel:ghostel)
          (define (browse-file-remote) "browsing")
          (define exported '())
          (define (calendar-export-after-save path) (set! exported (cons path exported)))
          (hooks:add! files:after-save calendar-export-after-save)
          (commands:define-command (open-notes) "notes")
          (tables:set! compile-angel:excluded "/init.el")
          (options:set! line-numbers:width 3)
          (define theme-state-file "~/.local/state/theme")
          (options:set! hel:want-minibuffer #f)
          (tables:set! auto-mode:file-names "go" go-ts:mode)
          (keys:bind! org/mouse:keymap "<mouse-1>" org:open-at-mouse)
          (hooks:add! prog:mode-hook
            (lambda ()
              (options:set-local! corfu:auto #t corfu:auto-delay 0.1 corfu:auto-prefix 2)
              (options:unset-local! symbols-outline:fetch-fn)))
          (import (gui-presentation))
          (keys:bind! keys:global "C-c g o" browse-file-remote)
          (keys:unbind! geiser/mode:keymap "M-.")
          (define prompts:yes-or-no? prompts:y-or-n?)
          (define agenda-refreshes 0)
          (define (refresh-agenda-files) (set! agenda-refreshes (+ agenda-refreshes 1)))
          (advice-add! org/agenda:agenda (lambda (agenda . arguments) (refresh-agenda-files) (apply agenda arguments)))
          (when (file-exists? "/bin/sh") (options:set! vertico:count 15))
          (saved:define-saved search-ring '() list?))))))

(define (at-repl form) (fixtures:at-repl form))

(test "the common forms of an Emacs configuration, written for Tuna, run with no report"
  (check-equal? '() (map (lambda (c) (list (and (who-condition? c) (condition-who c)) (fixtures:message c))) reports)))

(test "setq, :custom, :hook, :bind, defun, add-hook and :if take effect"
  (check-equal? '(#t #f #t #t "browsing" #t 15)
    (at-repl '(list (gptel/org:branching-context) (compile-angel:verbose) (recentf:enabled?)
                    (eq? (tables:ref keys:global "C-x m") ghostel:ghostel) (browse-file-remote)
                    (eq? (tables:ref keys:global "C-c g o") browse-file-remote) (vertico:count))))
  (check (plugins:commit 'vertico))
  (check-equal? '("cal.org" ("cal.org")) (at-repl '(list (files:save! "cal.org") exported))))

(test "a command defined by a plugin's macro in the configuration is a definition the plugin knows"
  (check-equal? '("notes" #t) (at-repl '(list (open-notes) (eq? (tables:ref commands:all 'open-notes) open-notes)))))

(test "add-to-list, setq-default, defvar, :init, :mode and with-eval-after-load take effect, an internal module's table included"
  (check-equal? '(#t 3 "~/.local/state/theme" #f #t #t)
    (at-repl '(list (tables:ref compile-angel:excluded "/init.el") (line-numbers:width) theme-state-file (hel:minibuffer?)
                    (eq? (tables:ref auto-mode:file-names "go") go-ts:mode)
                    (eq? (tables:ref org/mouse:keymap "<mouse-1>") org:open-at-mouse)))))

(test "setq-local from a mode hook sets local values in the scope the buffer makes current"
  (at-repl '(buffers-stub:enter!))
  (at-repl '(prog:mode))
  (check-equal? '(#t 0.1 2) (at-repl '(list (corfu:auto) (corfu:auto-delay) (corfu:auto-prefix))))
  (check-equal? '(init) (owner-name (at-repl '(tables:owner keys:global "C-x m")))))

(test "require of the user's own module, keymap-unset, advice and savehist's variables take effect"
  (check-equal? '("/home/groucho/src" presenting #f y-or-n ((agenda week) 1))
    (at-repl '(list (project:root) (gui-presentation:start!) (tables:ref geiser/mode:keymap "M-.") (prompts:yes-or-no? "Quit?")
                    (let ([agenda (org/agenda:agenda 'week)]) (list agenda agenda-refreshes)))))
  (at-repl '(saved:set! search-ring '("tuna")))
  (check-equal? '("tuna") (at-repl '(search-ring))))

(test "a command the commands plugin's macro defines in a module is changeable and exported"
  (fixtures:write-lib-module! '(my-commands) '((import (commands)) (commands:define-command (hello) "hello")))
  (at-repl '(import (my-commands)))
  (at-repl '(define my-commands:hello (lambda () "hi")))
  (check-equal? '("hi" ((repl) (my-commands)))
    (at-repl '(list (my-commands:hello) (map (lambda (change) (owner-name (car change))) (definition-changes my-commands:hello))))))

(test "a module may define a name #!tuna provides, such as map"
  (fixtures:write-lib-module! '(mapper) '((import (tables)) (tables:define-table map)))
  (check (at-repl '(begin (import (mapper)) (tables:table? mapper:map)))))

(test "a module named like a library built into Chez is Chez's"
  (fixtures:write-lib-module! '(scheme) '((define (mode) 'scheme)))
  (at-repl '(import (only (scheme) car)))
  (check-equal? 'chez-library (guard (c [#t 'chez-library]) (at-repl 'scheme:mode))))
