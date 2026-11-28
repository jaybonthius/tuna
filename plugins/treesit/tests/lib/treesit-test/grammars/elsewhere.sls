#!tuna
(import (languages))

(languages:define-grammar python (file (string-append (getenv "HOME") "/elsewhere/python.so")))
