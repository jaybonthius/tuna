#!tuna
(import (transient) (transient-test computed))

(transient:add-computed! transient-test/computed:menu "Computed"
  (lambda () (list (transient:command "q" "Replacement" transient-test/computed:note 'replacement))))
