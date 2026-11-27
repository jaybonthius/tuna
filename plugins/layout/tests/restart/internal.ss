(import (buffers))

(buffers:make " *internal*" "x\n")

(import (test) (layout) (views))

(test "the layout never starts on an internal buffer"
  (check-equal? "*scratch*" (buffers:name (views:buffer (layout:selected-view))))
  (check-equal? '(" *internal*" "*scratch*" " *layout*" " *popups*") (map buffers:name (buffers:all))))
