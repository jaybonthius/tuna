(import (tuna) (tuna plugins))
(define-saved history '() list?)
(set-saved! history (cons "start" (history)))
(import (console))
