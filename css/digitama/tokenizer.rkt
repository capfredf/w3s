#lang typed/racket

;;; https://drafts.csswg.org/css-syntax/#tokenization

(provide (all-defined-out))

(require "digicore.rkt")
(require "misc.rkt")

(struct css-srcloc ([in : Input-Port] [source : (U String Symbol)] [line : Natural] [col : Natural] [pos : Natural])
  #:type-name CSS-Srcloc)

(define-syntax (css-make-token stx)
  (syntax-case stx []
    [(_ src make-css:token datum ...)
     #'(let-values ([(start-position) (css-srcloc-pos src)]
                    [(line column position) (port-next-location (css-srcloc-in src))])
         (make-css:token (css-srcloc-source src) (css-srcloc-line src) (css-srcloc-col src)
                         start-position (or position 0) datum ...))]))
  
(define-syntax (css-make-bad-token stx)
  (syntax-case stx []
    [(_ src css:bad:sub token datum)
     #'(let ([bad (css-make-token src css:bad:sub (~s (cons (object-name token) datum)))])
         (css-log-read-error (css-token->string bad))
         bad)]))

(define css-consume-token : (-> Input-Port (U String Symbol) (U EOF CSS-Token))
  ;;; https://drafts.csswg.org/css-syntax/#error-handling
  ;;; https://drafts.csswg.org/css-syntax/#consume-a-token
  (lambda [/dev/cssin source]
    (define-values (line column position) (port-next-location /dev/cssin))
    (define srcloc (css-srcloc /dev/cssin source (or line 0) (or column 0) (or position 0)))
    (define ch (read-char /dev/cssin))
    (cond [(eof-object? ch) eof]
          [(char-whitespace? ch) (css-consume-whitespace-token srcloc)]
          [(char-numeric? ch) (css-consume-numeric-token srcloc ch)]
          [(css-char-name-prefix? ch) (css-consume-ident-token srcloc ch)]
          [else (case ch
                  [(#\( #\[ #\{) (css-make-token srcloc css:open ch)]
                  [(#\) #\] #\}) (css-make-token srcloc css:close ch)]
                  [(#\' #\") (css-consume-string-token srcloc ch)]
                  [(#\+ #\.) (css-consume-numeric-token srcloc ch)]
                  [(#\^ #\$ #\| #\~ #\*) (css-consume-match-token srcloc ch)]
                  [(#\#) (css-consume-hash-token srcloc)]
                  [(#\@) (css-consume-@keyword-token srcloc)]
                  [(#\/) (css-consume-comment-token srcloc)]
                  [(#\< #\-) (css-consume-cd-token srcloc ch)]
                  [(#\null) (css-make-token srcloc css:delim #\uFFFD)]
                  [(#\;) (css-make-token srcloc css:semicolon #\;)]
                  [(#\,) (css-make-token srcloc css:comma #\,)]
                  [(#\:) (css-make-token srcloc css:colon #\:)]
                  [else (css-make-token srcloc css:delim ch)])])))

(define css-consume-cd-token : (-> CSS-Srcloc Char CSS-Token)
  ;;; https://drafts.csswg.org/css-syntax/#CDO-token-diagram
  ;;; https://drafts.csswg.org/css-syntax/#CDC-token-diagram
  (lambda [srcloc open/close]
    (define css : Input-Port (css-srcloc-in srcloc))
    (if (char=? open/close #\<)
        (let ([cdo : (U EOF String) (peek-string 3 0 css)])
          (cond [(and (string? cdo) (string=? cdo "!--")) (read-string 3 css) (css-make-token srcloc css:cdo '<!--)]
                [else (css-make-token srcloc css:delim #\<)]))
        (let ([cdc : (U EOF String) (peek-string 2 0 css)])
          (cond [(eof-object? cdc) (css-make-token srcloc css:delim #\-)]
                [(string=? cdc "->") (read-string 2 css) (css-make-token srcloc css:cdc '-->)]
                [(css-identifier-prefix? #\- (string-ref cdc 0) (string-ref cdc 1)) (css-consume-ident-token srcloc #\-)]
                [else (css-consume-numeric-token srcloc #\-)])))))

(define css-consume-comment-token : (-> CSS-Srcloc (U CSS:WhiteSpace CSS:Delim CSS:Bad))
  (lambda [srcloc]
    (define css : Input-Port (css-srcloc-in srcloc))
    (define ch1 : (U EOF Char) (peek-char css 0))
    (cond [(or (eof-object? ch1) (not (char=? ch1 #\*))) (css-make-token srcloc css:slash #\/)]
          [(regexp-match #px".*?\\*/" css) => (λ [**/] (css-make-token srcloc css:whitespace (format "/~a" (car **/))))]
          [else (css-make-bad-token srcloc css:bad:eof struct:css:whitespace "/*")])))

(define css-consume-whitespace-token : (-> CSS-Srcloc CSS:WhiteSpace)
  (lambda [srcloc]
    (define css : Input-Port (css-srcloc-in srcloc))
    (css-consume-whitespace css)
    (css-make-token srcloc css:whitespace #\space)))
  
(define css-consume-ident-token : (-> CSS-Srcloc Char (U CSS:Ident CSS:Function CSS:URL CSS:URange CSS:Bad))
  ;;; https://drafts.csswg.org/css-syntax/#consume-an-ident-like-token
  ;;; https://drafts.csswg.org/css-syntax/#urange-syntax
  ;;; https://drafts.csswg.org/css-values/#urls
  ;;; https://drafts.csswg.org/css-variables/#defining-variables
  (lambda [srcloc id0]
    (define css : Input-Port (css-srcloc-in srcloc))
    (define ch1 : (U EOF Char) (peek-char css 0))
    (define ch2 : (U EOF Char) (peek-char css 1))
    (cond [(and (char-ci=? id0 #\u) (char? ch1) (char=? ch1 #\+)
                (or (char-hexdigit? ch2) (and (char? ch2) (char=? ch2 #\?))))
           (read-char css) (css-consume-unicode-range-token srcloc)]
          [else (let ([name (css-consume-name css id0)])
                  (define ch : (U EOF Char) (peek-char css))
                  (cond [(or (eof-object? ch) (not (char=? ch #\()))
                         (if (and (char=? id0 #\-) (eqv? id0 ch1))
                             (let ([--id (string->unreadable-symbol name)]) (css-make-token srcloc css:ident --id --id))
                             (css-make-token srcloc css:ident (string->symbol name) (string->symbol (string-downcase name))))]
                        [(and (or (not (string-ci=? name "url")) (regexp-match-peek #px"^.\\s*[\"']" css)) (read-char css))
                         (define fnorm : Symbol (string->symbol (string-downcase name)))
                         (css-make-token srcloc css:function (string->unreadable-symbol name) fnorm null #false)]
                        [else (read-char css) (css-consume-url-token srcloc)]))])))
      
(define css-consume-string-token : (-> CSS-Srcloc Char (U CSS:String CSS:Bad))
  ;;; https://drafts.csswg.org/css-syntax/#consume-a-string-token
  (lambda [srcloc quotation]
    (define css : Input-Port (css-srcloc-in srcloc))
    (let consume-string-token : (U CSS:String CSS:Bad) ([chars : (Listof Char) null])
      (define ch : (U EOF Char) (read-char css))
      (cond [(or (eof-object? ch) (char=? ch quotation))
             (when (eof-object? ch) (css-make-bad-token srcloc css:bad:eof struct:css:string (list->string (reverse chars))))
             (css-make-token srcloc css:string (list->string (reverse chars)))]
            [(char=? ch #\newline) (css-make-bad-token srcloc css:bad:eol struct:css:string (list->string (reverse chars)))]
            [(not (char=? ch #\\)) (consume-string-token (cons ch chars))]
            [else (let ([next (peek-char css)])
                    (cond [(eof-object? next) (consume-string-token chars)]
                          [(and (char=? next #\newline) (read-char css)) (consume-string-token (cons ch chars))]
                          [else (consume-string-token (cons (css-consume-escaped-char css) chars))]))]))))

(define css-consume-numeric-token : (-> CSS-Srcloc Char (U CSS-Numeric CSS:Delim CSS:Bad))
  ;;; https://drafts.csswg.org/css-syntax/#consume-a-number
  ;;; https://drafts.csswg.org/css-values/#numeric-types
  (lambda [srcloc sign/digit]
    (define css : Input-Port (css-srcloc-in srcloc))
    (define ch1 : (U EOF Char) (peek-char css 0))
    (define ch2 : (U EOF Char) (peek-char css 1))
    (cond [(not (css-number-prefix? sign/digit ch1 ch2)) (css-make-token srcloc css:delim sign/digit)]
          [else (let-values ([(n representation) (css-consume-number css sign/digit)])
                  (let ([ch1 : (U EOF Char) (peek-char css 0)]
                        [ch2 : (U EOF Char) (peek-char css 1)]
                        [ch3 : (U EOF Char) (peek-char css 2)])
                    (cond [(css-identifier-prefix? ch1 ch2 ch3)
                           (define unit : Symbol (string->symbol (string-downcase (css-consume-name css #false))))
                           (define value : Flonum (real->double-flonum n))
                           (define rep+unit : String (~a representation unit))
                           (case unit
                             [(em ex ch ic rem)       (css-make-token srcloc css:length:font     rep+unit value unit)]
                             [(vw vh vi vb vmin vmax) (css-make-token srcloc css:length:viewport rep+unit value unit)]
                             [(px cm mm q in pc pt)   (css-make-token srcloc css:length          rep+unit value unit)]
                             [(deg grad rad turn)     (css-make-token srcloc css:angle           rep+unit value unit)]
                             [(s ms min h)            (css-make-token srcloc css:time            rep+unit value unit)]
                             [(hz khz)                (css-make-token srcloc css:frequency       rep+unit value unit)]
                             [(dpi dpcm dppx x)       (css-make-token srcloc css:resolution      rep+unit value unit)]
                             [else                    (css-make-token srcloc css:dimension       rep+unit value unit)])]
                          [(and (char? ch1) (char=? ch1 #\%) (read-char css))
                           (define n% : Single-Flonum (real->single-flonum (* n 0.01)))
                           (css-make-token srcloc css:percentage (string-append representation "%") n%)]
                          [(flonum? n)
                           (cond [(zero? n) (css-make-token srcloc css:flzero representation n)]
                                 [(fl= n 1.0) (css-make-token srcloc css:flone representation n)]
                                 [else (css-make-token srcloc css:flonum representation n)])]
                          [(zero? n) (css-make-token srcloc css:zero representation n)]
                          [(= n 1) (css-make-token srcloc css:one representation n)]
                          [else (css-make-token srcloc css:integer representation n)])))])))

(define css-consume-url-token : (-> CSS-Srcloc (U CSS:URL CSS:Bad))
  ;;; https://drafts.csswg.org/css-syntax/#consume-a-url-token
  ;;; https://drafts.csswg.org/css-values/#urls
  ;;; https://drafts.csswg.org/css-values/#url-empty
  ;;; https://drafts.csswg.org/css-values/#about-invalid
  (lambda [srcloc]
    (define css : Input-Port (css-srcloc-in srcloc))
    (css-consume-whitespace css)
    (let consume-url-token ([srahc : (Listof Char) null])
      (define ch : (U EOF Char) (read-char css))
      (cond [(or (eof-object? ch) (char=? ch #\)))
             (define uri : (U String 'about:invalid) (if (null? srahc) 'about:invalid (list->string (reverse srahc))))
             (when (eof-object? ch) (css-make-bad-token srcloc css:bad:eof struct:css:url uri))
             (css-make-token srcloc css:url uri null #false)]
            [(and (char-whitespace? ch) (css-consume-whitespace css))
             (define end : (U EOF Char) (read-char css))
             (define uri : (U String 'about:invalid) (if (null? srahc) 'about:invalid (list->string (reverse srahc))))
             (cond [(or (eof-object? end) (char=? end #\))) (css-make-token srcloc css:url uri null #false)]
                   [else (css-consume-bad-url-remnants css (css-make-bad-token srcloc css:bad:blank struct:css:url uri))])]
            [(css-valid-escape? ch (peek-char css)) (consume-url-token (cons (css-consume-escaped-char css) srahc))]
            [(or (memq ch '(#\\ #\" #\' #\()) (css-char-non-printable? ch))
             (css-consume-bad-url-remnants css (css-make-bad-token srcloc css:bad:char struct:css:url ch))]
            [else (consume-url-token (cons ch srahc))]))))

(define css-consume-unicode-range-token : (-> CSS-Srcloc (U CSS:URange CSS:Bad))
  ;;; https://drafts.csswg.org/css-syntax/#urange-syntax
  (lambda [srcloc]
    (define css : Input-Port (css-srcloc-in srcloc))
    (define-values (n rest) (css-consume-hexadecimal (css-srcloc-in srcloc) 6))
    (define-values (start0 end0)
      (let consume-? : (Values Fixnum Fixnum) ([s : Fixnum n] [e : Fixnum n] [? : Fixnum rest])
        (cond [(zero? ?) (values s e)]
              [else (let ([ch : (U EOF Char) (peek-char css)])
                      (cond [(or (eof-object? ch) (not (char=? ch #\?))) (values s e)]
                            [else (read-char css) (consume-? (fxlshift s 4)
                                                             (fxior (fxlshift e 4) #xF)
                                                             (fx- ? 1))]))])))
    (define-values (start end)
      (cond [(not (fx= start0 end0)) (values start0 end0)]
            [else (let ([ch1 (peek-char css 0)]
                        [ch2 (peek-char css 1)])
                    (cond [(and (char? ch1) (char=? ch1 #\-) (char-hexdigit? ch2) (read-char css))
                           (define-values (end _) (css-consume-hexadecimal (css-srcloc-in srcloc) 6))
                           (values start0 end)]
                          [else (values start0 start0)]))]))
    (cond [(and (index? start) (index? end) (<= start end #x10FFFF)) (css-make-token srcloc css:urange (cons start end))]
          [(> end #x10FFFF) (css-make-bad-token srcloc css:bad:range struct:css:urange end)]
          [else (css-make-bad-token srcloc css:bad:range struct:css:urange (cons start end))])))

(define css-consume-hash-token : (-> CSS-Srcloc (U CSS:Hash CSS:Delim))
  ;;; https://drafts.csswg.org/css-syntax/#hash-token-diagram
  (lambda [srcloc]
    (define css : Input-Port (css-srcloc-in srcloc))
    (define ch1 : (U EOF Char) (peek-char css 0))
    (define ch2 : (U EOF Char) (peek-char css 1))
    (define ch3 : (U EOF Char) (peek-char css 2))
    (if (or (css-char-name? ch1) (css-valid-escape? ch1 ch2))
        (let ([name (css-consume-name (css-srcloc-in srcloc) #false)])
          (css-make-token srcloc css:hash (string->keyword name) #|(string->keyword (string-downcase name))|#))
        (css-make-token srcloc css:delim #\#))))

(define css-consume-@keyword-token : (-> CSS-Srcloc (U CSS:@Keyword CSS:Delim))
  ;;; https://drafts.csswg.org/css-syntax/#at-keyword-token-diagram
  (lambda [srcloc]
    (define css : Input-Port (css-srcloc-in srcloc))
    (define ch1 : (U EOF Char) (peek-char css 0))
    (define ch2 : (U EOF Char) (peek-char css 1))
    (define ch3 : (U EOF Char) (peek-char css 2))
    (if (css-identifier-prefix? ch1 ch2 ch3)
        (let ([name (css-consume-name (css-srcloc-in srcloc) #\@)])
          (css-make-token srcloc css:@keyword (string->keyword name) (string->keyword (string-downcase name))))
        (css-make-token srcloc css:delim #\@))))

(define css-consume-match-token : (-> CSS-Srcloc Char (U CSS:Match CSS:Delim))
  ;;; https://drafts.csswg.org/css-syntax/#include-match-token-diagram
  ;;; https://drafts.csswg.org/css-syntax/#column-token-diagram
  (lambda [srcloc prefix]
    (define css : Input-Port (css-srcloc-in srcloc))
    (define ch : (U EOF Char) (peek-char css))
    (cond [(and (eq? prefix #\|) (eq? ch #\|) (read-char css)) (css-make-token srcloc css:delim #\tab)]
          [(and (eq? ch #\=) (read-char css)) (css-make-token srcloc css:match prefix)]
          [(eq? prefix #\|) (css-make-token srcloc css:vbar prefix)]
          [else (css-make-token srcloc css:delim prefix)])))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define css-consume-whitespace : (-> Input-Port Void)
  (lambda [css]
    (regexp-match #px"\\s*" css)
    (void)))
  
(define css-consume-name : (-> Input-Port (Option Char) String)
  ;;; https://drafts.csswg.org/css-syntax/#consume-a-name
  (lambda [css ?head]
    (let consume-name ([srahc : (Listof Char) (if ?head (list ?head) null)])
      (define ch : (U EOF Char) (peek-char css))
      (cond [(and (css-char-name? ch) (read-char css)) (consume-name (cons ch srahc))]
            [(and (css-valid-escape? ch (peek-char css 1)) (read-char css)) (consume-name (cons (css-consume-escaped-char css) srahc))]
            [else (list->string (reverse srahc))]))))

(define css-consume-number : (-> Input-Port Char (Values (U Flonum Integer) String))
  ;;; https://drafts.csswg.org/css-syntax/#consume-a-number
  (lambda [css sign/digit]
    (let consume-number ([chars (list sign/digit)])
      (define ch : (U EOF Char) (peek-char css))
      (cond [(and (char? ch)
                  (or (char-numeric? ch)
                      (char=? ch #\+) (char=? ch #\-)
                      (css-decimal-point? ch (peek-char css 1))
                      (css-scientific-notation? ch (peek-char css 1) (peek-char css 2)))
                  (read-char css))
             (consume-number (cons ch chars))]
            [else (let* ([representation : String (list->string (reverse chars))]
                         [?number : (Option Complex) (string->number representation)])
                    (cond [(exact-integer? ?number) (values ?number representation)]
                          [(flonum? ?number) (values ?number representation)]
                          [else (values +nan.0 representation)]))]))))

(define css-consume-hexadecimal : (->* (Input-Port Byte) (Fixnum #:\s?$? Boolean) (Values Fixnum Byte))
  (lambda [css --count [result 0] #:\s?$? [eat-last-whitespace? #false]]
    (define hex : (U EOF Char) (peek-char css))
    (cond [(or (eof-object? hex) (not (char-hexdigit? hex)) (zero? --count))
           (when (and eat-last-whitespace? (char? hex) (char-whitespace? hex)) (read-char css))
           (values result --count)]
          [else (read-char css) (css-consume-hexadecimal #:\s?$? eat-last-whitespace?
                                                         css (fx- --count 1)
                                                         (fx+ (fxlshift result 4)
                                                              (char->hexadecimal hex)))])))

(define css-consume-escaped-char : (-> Input-Port Char)
  ;;; https://drafts.csswg.org/css-syntax/#consume-an-escaped-code-point
  (lambda [css]
    (define esc : (U EOF Char) (read-char css))
    (cond [(eof-object? esc) #\uFFFD]
          [(not (char-hexdigit? esc)) esc]
          [else (let-values ([(hex _) (css-consume-hexadecimal css (sub1 6) (char->hexadecimal esc) #:\s?$? #true)])
                  (cond [(or (fx<= hex 0) (fx> hex #x10FFFF)) #\uFFFD] ; #\nul and max unicode
                        [(<= #xD800 hex #xDFFF) #\uFFFD] ; surrogate
                        [else (integer->char hex)]))])))

(define css-consume-bad-url-remnants : (-> Input-Port CSS:Bad CSS:Bad)
  ;;; https://drafts.csswg.org/css-syntax/#consume-the-remnants-of-a-bad-url
  (lambda [css bad-url-token]
    (define ch : (U EOF Char) (read-char css))
    (cond [(or (eof-object? ch) (char=? ch #\))) bad-url-token]
          [(and (char=? ch #\\) (read-char css)) (css-consume-bad-url-remnants css bad-url-token)]
          [else (css-consume-bad-url-remnants css bad-url-token)])))
  
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define char-hexdigit? : (-> (U EOF Char) Boolean : #:+ Char)
  (lambda [ch]
    (and (char? ch)
         (or (char-numeric? ch)
             (char-ci<=? #\a ch #\f)))))

(define char->hexadecimal : (-> Char Fixnum)
  (lambda [hexch]
    (cond [(char<=? #\a hexch) (fx- (char->integer hexch) #x57)]
          [(char<=? #\A hexch) (fx- (char->integer hexch) #x37)]
          [else (fx- (char->integer hexch) #x30)])))

(define css-char-non-printable? : (-> (U EOF Char) Boolean : #:+ Char)
  (lambda [ch]
    (and (char? ch)
         (or (char<=? #\null ch #\backspace)
             (char=? ch #\vtab)
             (char<=? #\u000E ch #\u001F)
             (char=? ch #\rubout)))))

(define css-char-name-prefix? : (-> (U EOF Char) Boolean : #:+ Char)
  (lambda [ch]
    (and (char? ch)
         (or (char-lower-case? ch)
             (char-upper-case? ch)
             (char=? #\_  ch)
             (char>=? ch #\u0080)))))

(define css-char-name? : (-> (U EOF Char) Boolean : #:+ Char)
  (lambda [ch]
    (and (char? ch)
         (or (css-char-name-prefix? ch)
             (char-numeric? ch)
             (char=? #\- ch)))))
  
(define css-valid-escape? : (-> (U EOF Char) (U EOF Char) Boolean : #:+ Char)
  ;;; https://drafts.csswg.org/css-syntax/#escaping
  ;;; https://drafts.csswg.org/css-syntax/#starts-with-a-valid-escape
  (lambda [ch1 ch2]
    (and (char? ch1)
         (char=? ch1 #\\)
         (or (eof-object? ch2)
             (not (char=? ch2 #\newline))))))

(define css-identifier-prefix? : (-> (U EOF Char) (U EOF Char) (U EOF Char) Boolean : #:+ Char)
  ;;; https://drafts.csswg.org/css-syntax/#would-start-an-identifier
  (lambda [ch1 ch2 ch3]
    (or (css-char-name-prefix? ch1)
        (css-valid-escape? ch1 ch2)
        (and (char? ch1) (char=? ch1 #\-)
             (or (css-char-name-prefix? ch2)
                 (and (char? ch2) (char=? ch2 #\-))
                 (css-valid-escape? ch2 ch3))))))

(define css-number-prefix? : (-> (U EOF Char) (U EOF Char) (U EOF Char) Boolean : #:+ Char)
  ;;; https://drafts.csswg.org/css-syntax/#starts-with-a-number
  (lambda [ch1 ch2 ch3]
    (or (and (char? ch1) (char<=? #\0 ch1 #\9))
        (and (char? ch1) (char? ch2)
             (char=? ch1 #\.) (char<=? #\0 ch2 #\9))
        (and (char? ch1) (char? ch2)
             (or (char=? ch1 #\+) (char=? ch1 #\-))
             (or (char<=? #\0 ch2 #\9)
                 (and (char=? ch2 #\.)
                      (char? ch3) (char<=? #\0 ch3 #\9)))))))

(define css-scientific-notation? : (-> (U EOF Char) (U EOF Char) (U EOF Char) Boolean : #:+ Char)
  ;;; https://drafts.csswg.org/css-syntax/#consume-a-number
  (lambda [ch1 ch2 ch3]
    (and (char? ch1) (char? ch2)
         (char-ci=? ch1 #\e)
         (or (char<=? #\0 ch2 #\9)
             (and (or (char=? ch2 #\+) (char=? ch2 #\-))
                  (char? ch3)
                  (char<=? #\0 ch3 #\9))))))

(define css-decimal-point? : (-> (U EOF Char) (U EOF Char) Boolean : #:+ Char)
  ;;; https://drafts.csswg.org/css-syntax/#consume-a-number
  (lambda [ch1 ch2]
    (and (char? ch1) (char? ch2)
         (char=? ch1 #\.)
         (char<=? #\0 ch2 #\9))))