(import (test))

(test "the configuration loads as a task, which may pause"
  (check (task? configuration-task))
  (check-equal? 'done (task-state configuration-task))
  (check-equal? 42 answer))
