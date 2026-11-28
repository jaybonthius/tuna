(import (tuna) (test) (test-runner) (sampler) (metrics) (machine))

(define viewer (make-owner '(viewer reload)))

(test "a reload of sampler and its importers"
  (call-as-owner viewer (lambda () (sampler:want machine:cpu 0.5)))
  (test-runner:wait-until (lambda () (sampler:last-time machine:cpu)))
  (reload-modules! '((sampler))))

;; Each form is compiled when it is reached, so this one names the new
;; instances.
(test "keeps the wants of every owner, and the source reads again, filling the metric"
  (check-equal? (list (cons viewer 0.5)) (sampler:wants machine:cpu))
  (test-runner:wait-until (lambda () (sampler:last-time machine:cpu)))
  (test-runner:wait-until (lambda () (metrics:latest machine:cpu-usage '())))
  (unload-owner! viewer)
  (check-equal? #f (sampler:interval machine:cpu)))
