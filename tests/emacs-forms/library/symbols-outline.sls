#!tuna
(import (options))
(options:define-option fetch-fn #f (lambda (v) (or (not v) (procedure? v))))
