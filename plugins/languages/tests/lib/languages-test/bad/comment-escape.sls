#!tuna
(import (languages))

(languages:define-language "x" (line-comments ("#" (escape #\\))))
