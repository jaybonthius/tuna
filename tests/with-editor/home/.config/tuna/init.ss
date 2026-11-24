(import (tuna) (testing) (tuna plugins) (web) (keys) (commands) (document) (buffers) (views))
(define said '())
(use-plugin ask
  (config
    (set-option! ask:message-writer (lambda (text) (set! said (cons text said))))))
(define (take-said!) (let ([s (reverse said)]) (set! said '()) s))
(use-plugin layout)
(use-plugin files)
(use-plugin git)
(use-plugin with-editor)
(import (processes))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))


(define home (getenv "HOME"))

(define (at path) (string-append home "/" path))

(define (text b) (document:text (buffers:document b)))

(define (shown) (let ([b (views:buffer (layout:selected-view))]) (and b (buffers:name b))))

(putenv "GIT_AUTHOR_NAME" "Tuna")
(putenv "GIT_AUTHOR_EMAIL" "tuna@example.org")
(putenv "GIT_COMMITTER_NAME" "Tuna")
(putenv "GIT_COMMITTER_EMAIL" "tuna@example.org")

(define (sh command)
  (unless (zero? (system (string-append "{ set -e; cd \"$HOME\"; " command "; } < /dev/null > /dev/null 2>&1")))
    (error 'sh "failed" command)))

(define (subjects repo) (utf8->string (git:query repo '("log" "--format=%s"))))

(sh "mkdir tmp")
(putenv "TMPDIR" (at "tmp"))

(define (request-folders) (directory-list (at "tmp")))
(import (console))
