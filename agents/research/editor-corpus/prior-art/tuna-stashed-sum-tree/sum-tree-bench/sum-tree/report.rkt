#lang racket/base

(require racket/file)

(provide validate-stage2-report-candidate
         publish-stage2-report-candidate)

(define approval-claim-pattern
  (pregexp
    (string-append
      "(?i:owner[- ]approved|approved by (?:the )?owner|"
      "owner approval(?: status)?[ ]*:[ ]*approved)")))
(define selected-policy-pattern
  #px"(?i:B[ ]*=[ ]*32|C[ ]*=[ ]*1024|compaction)")

(define (validate-stage2-report-candidate candidate
                                          #:approval-state
                                          [approval-state 'pending])
  (unless (string? candidate)
    (raise-argument-error 'validate-stage2-report-candidate "string?" candidate))
  (unless (memq approval-state '(pending approved))
    (raise-argument-error 'validate-stage2-report-candidate
                          "(or/c 'pending 'approved)"
                          approval-state))
  (when (and (eq? approval-state 'pending)
             (regexp-match? approval-claim-pattern candidate)
             (regexp-match? selected-policy-pattern candidate))
    (raise-arguments-error
      'validate-stage2-report-candidate
      "pending approval cannot be described as owner-approved"
      "candidate" candidate))
  candidate)

(define (publish-stage2-report-candidate candidate output-path
                                         #:approval-state
                                         [approval-state 'pending]
                                         #:before-publish
                                         [before-publish void])
  (validate-stage2-report-candidate candidate
                                    #:approval-state approval-state)
  (define target (simplify-path (path->complete-path output-path) #f))
  (make-parent-directory* target)
  (define-values (base name _directory?) (split-path target))
  (define parent (if (path? base) base (current-directory)))
  (define temporary
    (make-temporary-file ".sum-tree-report-candidate~a.md" #f parent))
  (with-handlers ([exn?
                   (lambda (exception)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise exception))])
    (call-with-output-file temporary
      #:exists 'truncate
      (lambda (output) (display candidate output)))
    (define read-back (file->string temporary))
    (validate-stage2-report-candidate read-back
                                      #:approval-state approval-state)
    (unless (equal? read-back candidate)
      (raise-arguments-error
        'publish-stage2-report-candidate
        "candidate report changed during read-back"
        "target" name))
    (before-publish)
    (rename-file-or-directory temporary target #t)))

