#lang typed/racket/base

;;; https://www.w3.org/TR/xml/#sec-documents

(provide (all-defined-out))

(require racket/path)

(require "dtd.rkt")
(require "doctype.rkt")
(require "grammar.rkt")
(require "normalize.rkt")

(require "digicore.rkt")
(require "stdin.rkt")

(require "tokenizer/port.rkt")
(require "tokenizer/grammar.rkt")
(require "tokenizer.rkt")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-type (XML-External-Entityof type) (U False type (-> Path (Option String) (Option String) (Option type))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(struct xml-document
  ([doctype : XML-DocType]
   [internal-dtd : XML-Plain-DTD]
   [elements : (Listof XML-Content)])
  #:transparent
  #:type-name XML-Document)

(struct xml-document*
  ([doctype : XML-DocType]
   [internal-dtd : XML-DTD]
   [external-dtd : (Option XML-DTD)]
   [type : (Option XML-Type)]
   [elements : (Listof XML-Content*)])
  #:transparent
  #:type-name XML-Document*)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define read-xml-document : (-> SGML-StdIn XML-Document)
  (lambda [/dev/rawin]
    (define-values (/dev/xmlin version encoding standalone?) (xml-open-input-port /dev/rawin #false))
    (define tokens : (Listof XML-Datum) (read-xml-tokens /dev/xmlin))
    (define-values (doctype dtd grammars) (xml-syntax->content tokens))
    (define-values (maybe-name external) (xml-doctype-values doctype))
    
    (define name : Symbol
      (cond [(or maybe-name) maybe-name]
            [else (let ([maybe-first-element (findf list? grammars)])
                    (cond [(pair? maybe-first-element) (car maybe-first-element)]
                          [else '||]))]))

    (xml-document (xml-doctype (sgml-port-name /dev/xmlin) version encoding standalone? name external)
                  dtd grammars)))

(define read-xml-document* : (->* (SGML-StdIn)
                                  ((XML-External-Entityof XML-DTD)
                                   #:normalize? Boolean #:xml:lang String #:xml:space Symbol #:xml:space-filter (Option XML:Space-Filter))
                                  XML-Document*)
  (lambda [#:normalize? [normalize? #false] #:xml:lang [xml:lang ""] #:xml:space [xml:space 'default] #:xml:space-filter [xml:space-filter #false]
           /dev/rawin [ext-dtd #false]]
    (define-values (/dev/xmlin version encoding standalone?) (xml-open-input-port /dev/rawin #true))
    (define source : (U Symbol String) (sgml-port-name /dev/xmlin))
    (define tokens : (Listof XML-Token) (read-xml-tokens* /dev/xmlin source))
    (define-values (doctype definitions grammars) (xml-syntax->content* tokens))
    (define-values (maybe-name external) (xml-doctype-values doctype))
    
    (define name : Symbol
      (cond [(or maybe-name) maybe-name]
            [else (let ([maybe-first-element (findf list? grammars)])
                    (cond [(pair? maybe-first-element) (xml:name-datum (car maybe-first-element))]
                          [else '||]))]))

    (define ?external-dtd : (Option XML-DTD) (xml-load-external-dtd source ext-dtd external))

    (define doc : XML-Document*
      (xml-document* (xml-doctype source version encoding standalone? name external)
                     (xml-make-type-definition source definitions) ?external-dtd
                     #false grammars))

    (cond [(not normalize?) doc]
          [else (xml-document*-normalize #:xml:lang xml:lang
                                         #:xml:space xml:space #:xml:space-filter xml:space-filter
                                         doc)])))

(define xml-document*-normalize : (->* (XML-Document*)
                                       ((XML-External-Entityof XML-DTD)
                                        #:xml:lang String #:xml:space Symbol #:xml:space-filter (Option XML:Space-Filter))
                                       XML-Document*)
  (lambda [#:xml:lang [xml:lang ""] #:xml:space [xml:space 'default] #:xml:space-filter [xml:space-filter #false] doc [alter-ext-dtd #false]]
    (define-values (type contents)
      (xml-normalize (xml-document*-internal-dtd doc)
                     (or (let ([doctype (xml-document*-doctype doc)])
                           (xml-load-external-dtd (xml-doctype-location doctype)
                                                  alter-ext-dtd
                                                  (xml-doctype-external doctype)))
                         (xml-document*-external-dtd doc))
                     (xml-document*-elements doc)
                     xml:lang xml:space xml:space-filter))
    
    (xml-document* (xml-document*-doctype doc)
                   (xml-document*-internal-dtd doc) (xml-document*-external-dtd doc)
                   type contents)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define read-xml-document*->document : (-> XML-Document* XML-Document)
  (lambda [doc.xml]
    (xml-document (xml-document*-doctype doc.xml)
                  (make-hasheq)
                  (map xml-content->datum (xml-document*-elements doc.xml)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define xml-content->datum : (-> XML-Content* XML-Content)
  (lambda [g]
    (cond [(list? g) (xml-element->datum g)]
          [else (xml-pi->datum g)])))

(define xml-pi->datum : (-> XML-Processing-Instruction* XML-Processing-Instruction)
  (lambda [p]
    (mcons (xml:name-datum (mcar p))
           (let ([body (mcdr p)])
             (and body
                  (xml:string-datum body))))))

(define xml-element->datum : (-> XML-Element* XML-Element)
  (lambda [e]
    (list (xml:name-datum (car e))
          (map xml-pair->datum (cadr e))
          (map (λ [[child : (U XML-Subdatum* XML-Element*)]]
                 (cond [(list? child) (xml-element->datum child)]
                       [(xml:string? child) (xml:string-datum child)]
                       [(xml-cdata-token? child)
                        (cond [(xml:newline? child) (xml-new-line (xml:whitespace-datum child))]
                              [(xml:comment? child) (xml-comment (xml:whitespace-datum child))]
                              [else (xml-white-space (or (xml-cdata-token->datum child) ""))])]
                       [(xml-reference-token? child)
                        (cond [(xml:reference? child) (xml:reference-datum child)]
                              [(xml:char? child) (xml:char-datum child)]
                              [else '|&DEADC0DE;|])]
                       [else (xml-pi->datum child)]))
               (caddr e)))))

(define xml-pair->datum : (-> (Pairof XML:Name XML:String) (Pairof Symbol String))
  (lambda [p]
    (cons (xml:name-datum (car p)) (xml:string-datum (cdr p)))))

(define xml-load-external-dtd : (-> (U String Symbol) (XML-External-Entityof XML-DTD) XML-External-ID (Option XML-DTD))
  (lambda [source ext-dtd external]
    (define rootdir : Path
      (or (and (string? source)
               (path-only source))
          (current-directory)))
    
    (cond [(xml-dtd? ext-dtd) ext-dtd]
          [(not ext-dtd) #false]
          [(not external) (ext-dtd rootdir #false #false)]
          [(string? external) (ext-dtd rootdir external #false)]
          [else (ext-dtd rootdir (car external) (cdr external))])))
