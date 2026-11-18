#!tuna
(import (transient) (computed))

(transient:add-computed! computed:menu "Computed"
  (lambda () (list (transient:command "q" "Replacement" computed:note 'replacement))))
