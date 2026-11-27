#!tuna
(import (transient) (transient-test magit) (commands))

(define %squashes '())

(define (squashes) %squashes)

(commands:define-command (squash-branch [arguments (transient:arguments transient-test/magit:merge-menu)])
  "Squashes a branch into the current one with ARGUMENTS."
  (set! %squashes (cons arguments %squashes)))

(transient:add! transient-test/magit:merge-menu "Actions"
  (transient:command "m" "Squash instead" squash-branch))
(transient:add! transient-test/magit:merge-menu "More"
  (transient:command "s" "Squash" squash-branch))
