#!tuna
(import (languages))

(languages:define-grammar python (file (string-append (getenv "HOME") "/nowhere/python.so")))
