#lang racket/base

;; Domain tests for the Taskboard example. These run without a window and
;; without touching the user's application data.

(require json
         rackunit
         racket/list
         "../taskboard.rkt")

(define (titles tasks)
  (map (lambda (task) (hash-ref task 'title)) tasks))

(define now 1730000000)

;; ---- empty state ----

(check-equal? empty-tasks '())
(check-equal? (task-stats empty-tasks) (hasheq 'total 0 'done 0 'open 0))
(check-true (task-list? empty-tasks))
(check-false (task? (hasheq 'id 0 'title "x")))

;; ---- add ----

(define one (task-add empty-tasks "  Ship the example  " now))
(check-true (task-list? one))
(check-equal? (length one) 1)
(check-equal? (hash-ref (first one) 'title) "Ship the example")
(check-equal? (hash-ref (first one) 'id) 0)
(check-false (hash-ref (first one) 'done))
(check-equal? (hash-ref (first one) 'created) now)

(define two (task-add one "Review the schema" (add1 now)))
(check-equal? (map (lambda (task) (hash-ref task 'id)) two) '(0 1))
(check-equal? (titles two) '("Ship the example" "Review the schema"))

;; Rejected inputs return #f instead of raising, so the route layer can
;; answer 400 without a second validation pass.
(check-false (task-add empty-tasks "   " now))
(check-false (task-add empty-tasks "" now))
(check-false (task-add empty-tasks (make-string (add1 max-title-length) #\x) now))
(check-false (task-add empty-tasks "valid" "not-a-timestamp"))
(check-false (task-add empty-tasks 42 now))
(check-not-false (task-add empty-tasks (make-string max-title-length #\x) now))

;; ---- toggle ----

(define toggled (task-toggle two 1))
(check-true (hash-ref (second toggled) 'done))
(check-false (hash-ref (first toggled) 'done))
(check-equal? (titles toggled) (titles two) "toggle does not reorder")

(check-false (hash-ref (second (task-toggle toggled 1)) 'done) "toggle is reversible")

(define untouched (task-toggle two 999))
(check-equal? (map (lambda (task) (hash-ref task 'done)) untouched) '(#f #f))

;; ---- remove and clear ----

(check-equal? (titles (task-remove two 0)) '("Review the schema"))
(check-equal? (length (task-remove two 999)) 2)

(define mixed
  (list (hasheq 'id 0 'title "a" 'done #t 'created now)
        (hasheq 'id 1 'title "b" 'done #f 'created now)
        (hasheq 'id 2 'title "c" 'done #t 'created now)))
(check-equal? (titles (task-clear-done mixed)) '("b"))

;; ---- stats ----

(check-equal? (task-stats two) (hasheq 'total 2 'done 0 'open 2))
(check-equal? (task-stats (task-toggle two 0)) (hasheq 'total 2 'done 1 'open 1))
(check-equal? (task-stats (task-clear-done (task-toggle two 0))) (hasheq 'total 1 'done 0 'open 1))

;; ---- JSON round-trip ----

(define decoded (string->jsexpr (jsexpr->string toggled)))
(check-true (task-list? decoded))
(check-equal? (task-stats decoded) (task-stats toggled))
(check-equal? (titles decoded) (titles toggled))
