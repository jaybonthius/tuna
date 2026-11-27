#!tuna
(import (entries target) (entries helper) (hooks))
(hooks:add! entries/target:greeted entries/helper:shout)
(advice-add! entries/target:text entries/helper:wrap)
