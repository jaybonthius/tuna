#!tuna
(import (entries target) (entries helper) (hooks) (tables))
(hooks:remove! entries/target:greeted entries/helper:shout)
(advice-remove! entries/target:text entries/helper:wrap)
(tables:remove! entries/target:names 'harpo)
