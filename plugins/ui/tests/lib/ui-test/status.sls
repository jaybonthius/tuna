#!tuna
(import (ui) (buffers))

(buffers:define-kind header)

(buffers:define-kind status (content nodes))

(define (status-datum . sections)
  (apply status '() (header '() "Head:     main Second commit\n") sections))

(define (hunk heading . lines) (apply ui:section `((type . hunk) (value . ,heading)) heading lines))

(define (file path . hunks) (apply ui:section `((type . file) (value . ,path)) (string-append "modified   " path) hunks))
