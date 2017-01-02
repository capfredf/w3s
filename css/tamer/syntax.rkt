#lang typed/racket

(require "configure.rkt")
(require "../syntax.rkt")
(require "../sugar.rkt")

(css-configure-@media)
(collect-garbage)
(define tamer-sheet : CSS-StyleSheet (time-run (read-css-stylesheet tamer/tamer.css)))
(define tamer-root : CSS-Subject (make-css-subject #:type 'root #:id '#:header))
(define tamer-body : CSS-Subject (make-css-subject #:type 'module #:id '#:root #:classes '(main)))

(define css-all-filter : (CSS-Cascaded-Value-Filter (HashTable Symbol Any))
  (lambda [declared-values inherited-values]
    (for/hash : (HashTable Symbol Any) ([desc-name (in-hash-keys (css-values-descriptors declared-values))])
      (values desc-name (css-ref declared-values inherited-values desc-name)))))

(define css-declaration-parsers : CSS-Declaration-Parsers
  (lambda [suitcased-name !]
    (λ [[initial : (Listof CSS-Datum)] [declared-values : (Listof CSS-Token)]]
      (values (map css-token->datum declared-values) null))))

tamer-root
(match-define (list preference header-preference)
  (time-run (let-values ([(preference for-children)
                          (css-cascade (list tamer-sheet) (list tamer-root)
                                       css-declaration-parsers css-all-filter
                                       #false)])
              (list preference for-children))))
header-preference

tamer-body
(time-run (let-values ([(preference for-children)
                        (css-cascade (list tamer-sheet) (list tamer-body tamer-root)
                                     css-declaration-parsers css-all-filter
                                     header-preference)])
            for-children))