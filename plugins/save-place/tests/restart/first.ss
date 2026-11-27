(import (views) (files) (visits) (save-place))

(visits:write-file! "a.txt" "one\ntwo\nthree\nfour\nfive\nsix\n")
(visits:write-file! "b.txt" "b one\nb two\nb three\n")
(visits:leave! "a.txt" 9)
(visits:leave! "b.txt" 4)
(define open-view (views:make (files:visit (visits:home-file "a.txt"))))
(views:set-point! open-view 20)
