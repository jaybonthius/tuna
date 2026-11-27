(import (tuna) (options) (commands) (buffers) (files) (session))

(options:set! files:confirm-exit? #t)
(buffers:replace! (files:visit (session:home-path "d.txt")) 1 1 "edit")
(commands:run files:save-buffers-kill-tuna)
