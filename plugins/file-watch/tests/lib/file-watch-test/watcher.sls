#!tuna
(import (file-watch) (file-watch-test))

(define watch (file-watch:watch! (file-watch-test:home "w/c.txt") file-watch-test:recorder))
