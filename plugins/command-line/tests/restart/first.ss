(import (tuna) (test-user) (buffers) (document) (views) (layout) (files) (command-line-test))

(command-line-test:lines-file! "g.txt" 300 "line")
(command-line-test:lines-file! "h.txt" 300 "row")

(let ([v (layout:selected-view)] [g (files:visit (command-line-test:home-path "g.txt"))])
  (layout:switch-to-buffer g)
  (views:set-point! v (document:length (buffers:document g)))
  (views:scroll-to! v (views:point v) (views:align bottom)))

(test-user:settle)
