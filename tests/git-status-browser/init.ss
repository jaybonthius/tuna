(import (tuna))
(use-plugin jobs)
(use-plugin web)
(use-plugin design-tokens)
(use-plugin faces)
(use-plugin views)
(use-plugin keys)
(use-plugin ui)
(use-plugin layout)
(use-plugin layout-split)
(use-plugin modes)
(use-plugin files)
(use-plugin undo)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin status-line)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin file-picker)
(use-plugin transient)
(use-plugin command-line)
(use-plugin git-status)
(import (console) (git) (git-mode) (buffers) (document) (processes))

(define (repo) (git:find-repository (string-append (current-directory) "/repo")))

(define (show-status) (git-status:show (repo)) #t)

(define (status-view) (find (lambda (v) (git-status:buffer? (views:buffer v))) (layout:views)))

(define (point-and-selected) (list (views:point (status-view)) (eq? (layout:selected-view) (status-view))))

;; A plain git status may take the index lock to refresh it, and fail
;; the command a click runs at the same time.
(define (short)
  (let-values ([(s o e) (processes:run "git" '("--no-optional-locks" "status" "--short") #f (processes:options [directory (git:repository-root (repo))]))])
    (utf8->string o)))

(define (current?) (git-mode:wait-until-current (views:buffer (status-view))) #t)

(define (show-file! side path)
  (let ([s (ui:find-section (views:buffer (status-view)) (list (cons 'file path) (cons side #f)))])
    (ui:show-section! (status-view) s)
    #t))
