(import (views) (files) (save-place-test visits) (save-place))

(save-place-test/visits:write-file! "a.txt" "one\ntwo\nthree\nfour\nfive\nsix\n")
(save-place-test/visits:write-file! "b.txt" "b one\nb two\nb three\n")
(save-place-test/visits:leave! "a.txt" 9)
(save-place-test/visits:leave! "b.txt" 4)
(define open-view (views:make (files:visit (save-place-test/visits:home-file "a.txt"))))
(views:set-point! open-view 20)
