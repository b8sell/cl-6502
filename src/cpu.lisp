(in-package :6502-cpu)

;;;; REFERENCES:
;; http://www.obelisk.demon.co.uk/6502/registers.html
;; http://www.obelisk.demon.co.uk/6502/addressing.html
;; http://nesdev.parodius.com/6502.txt

(defstruct cpu
  "A 6502 CPU with an extra slot for tracking the cycle count/clock ticks."
  (pc #xfffc :type (unsigned-byte 16))  ;; program counter
  (sp #xff   :type (unsigned-byte 8))   ;; stack pointer
  (sr #x30   :type (unsigned-byte 8))   ;; status register
  (xr 0      :type (unsigned-byte 8))   ;; x register
  (yr 0      :type (unsigned-byte 8))   ;; y register
  (ar 0      :type (unsigned-byte 8))   ;; accumulator
  (cc 0      :type fixnum))             ;; cycle counter

;;; Tasty Globals

(defparameter *ram* (make-array #x10000 :element-type '(unsigned-byte 8))
  "A lovely hunk of bytes.")

(defparameter *cpu* (make-cpu)
  "The 6502 instance used by opcodes in the package.")

(defparameter *opcodes* (make-array #x100 :element-type 'cons
                                    :initial-element nil)
  "A mapping of opcodes to instruction mnemonic/metadata conses.")

;;; Helpers

(defun load-image (&key (cpu (make-cpu))
                   (ram (make-array #x10000 :element-type '(unsigned-byte 8))))
  "Set *CPU* and *RAM* to CPU and RAM."
  (setf *ram* ram *cpu* cpu))

(defun save-image ()
  "Return a list containing the current *CPU* and *RAM*."
  (list *cpu* *ram*))

(defun reset ()
  "Reset the virtual machine to an initial state."
  (load-image))

(defun get-instruction (opcode)
  "Get the mnemonic for OPCODE. Returns a symbol to be funcalled or nil."
  (first (aref *opcodes* opcode)))

(defun get-byte (address)
  "Get a byte from RAM at the given address."
  (aref *ram* address))

(defun (setf get-byte) (new-val address)
  "Set ADDRESS in *ram* to NEW-VAL."
  (setf (aref *ram* address) new-val))

(defun get-word (address &optional wrap-p)
  "Get a word from RAM starting at the given address."
  (+ (get-byte address)
     (ash (get-byte (if wrap-p (wrap-page address) (1+ address))) 8)))

(defun (setf get-word) (new-val address)
  "Set ADDRESS and (1+ ADDRESS) in *ram* to NEW-VAL, little endian ordering."
  (setf (get-byte address) (wrap-byte (ash new-val -8))
        (get-byte (1+ address)) (wrap-byte new-val)))

(defun get-range (start &optional end)
  "Get a range of bytes from RAM, starting from START and stopping at END if
provided."
  (subseq *ram* start end))

(defun (setf get-range) (bytevector start)
  "Replace the contents of RAM, starting from START with BYTEVECTOR."
  (let ((size (length bytevector)))
    (setf (subseq *ram* start (+ start size)) bytevector)))

(defun wrap-byte (val)
  "Wrap the given value to ensure it conforms to (typep val '(unsigned-byte 8)),
e.g. a Stack Pointer or general purpose register."
  (logand val #xff))

(defun wrap-word (val)
  "Wrap the given value to ensure it conforms to (typep val '(unsigned-byte 16)),
e.g. a Program Counter address."
  (logand val #xffff))

(defmethod wrap-stack ((cpu cpu))
  "Wrap the stack pointer."
  (setf (cpu-sp cpu) (wrap-byte (cpu-sp cpu))))

(defun wrap-page (address)
  "Wrap the given ADDRESS, ensuring that we don't cross a page boundary.
e.g. When the last two bytes of ADDRESS are #xff."
  (+ (logand address #xff00)
     (logand (1+ address) #xff)))

(defun stack-push (value cpu)
  "Push the given VALUE on the stack and decrement the SP."
  (setf (get-byte (+ (cpu-sp cpu) #x100)) (wrap-byte value))
  (decf (cpu-sp cpu))
  (wrap-stack cpu))

(defun stack-push-word (value cpu)
  "Push the 16-bit word VALUE onto the stack."
  (stack-push (wrap-byte (ash value -8)) cpu)
  (stack-push (wrap-byte value) cpu))

(defun stack-pop (cpu)
  "Pop the value pointed to by the SP and increment the SP."
  (incf (cpu-sp cpu))
  (wrap-stack cpu)
  (get-byte (+ (cpu-sp cpu) #x100)))

(defun stack-pop-word (cpu)
  "Pop a 16-bit word off the stack."
  (+ (stack-pop cpu) (ash (stack-pop cpu) 8)))

(defun %status-bit (key)
  (let ((status-register '((:carry     . 0)
                           (:zero      . 1)
                           (:interrupt . 2)
                           (:decimal   . 3)
                           (:break     . 4)
                           (:unused    . 5)
                           (:overflow  . 6)
                           (:negative  . 7))))
    (rest (assoc key status-register))))

(defun status-bit (key cpu)
  "Retrieve bit KEY from the status register of CPU. KEY should be a keyword."
  (ldb (byte 1 (%status-bit key)) (cpu-sr cpu)))

(defun (setf status-bit) (new-val key cpu)
  "Set bit KEY in the status reg of CPU to NEW-VAL. KEY should be a keyword."
  (if (or (zerop new-val) (= 1 new-val))
      (setf (ldb (byte 1 (%status-bit key)) (cpu-sr cpu)) new-val)
      (error 'status-bit-error :index (%status-bit key))))

(defun set-flags-if (cpu &rest flag-preds)
  "Takes any even number of arguments where the first is a keyword denoting a
status bit and the second is a funcallable predicate that takes no arguments.
It will set each flag to 1 if its predicate is true, otherwise 0."
  (assert (evenp (length flag-preds)))
  (loop for (flag pred . nil) on flag-preds by #'cddr
     do (setf (status-bit flag cpu) (if (funcall pred) 1 0))))

(declaim (inline set-flags-nz))
(defun set-flags-nz (cpu value)
  "Set the zero and negative bits of CPU's staus-register based on VALUE."
  (set-flags-if cpu :zero (lambda () (zerop value))
                :negative (lambda () (logbitp 7 value))))

(defun maybe-update-cycle-count (cpu address &optional start)
  "If ADDRESS crosses a page boundary, add an extra cycle to CPU's count. If
START is provided, test that against ADDRESS. Otherwise, use (absolute cpu)."
  (when (not (= (logand (or start (absolute cpu)) #xff00)
                (logand address #xff00)))
    (incf (cpu-cc cpu))))

(defun branch-if (predicate cpu)
  "Take a Relative branch if PREDICATE is true, otherwise increment the PC."
  (if (funcall predicate)
      (setf (cpu-pc cpu) (relative cpu))
      (incf (cpu-pc cpu))))

; Stolen and slightly hacked up from Cliki. Thanks cliki!
(defun rotate-byte (integer &optional (count 1) (size 8))
  "Rotate the bits of INTEGER by COUNT. If COUNT is negative, rotate right
instead of left. SIZE specifies the bitlength of the integer being rotated."
  (let* ((count (mod count size))
         (bytespec (byte size 0)))
    (labels ((rotate-byte-from-0 (count integer)
               (if (> count 0)
                   (logior (ldb bytespec (ash integer count))
                           (ldb bytespec (ash integer (- count size))))
                   (logior (ldb bytespec (ash integer count))
                           (ldb bytespec (ash integer (+ count size)))))))
      (dpb (rotate-byte-from-0 count (ldb bytespec integer))
           bytespec
           integer))))

;;; Addressing

(defmacro defaddress (name (&key cpu-reg (docs "")) &body body)
  "Define an Addressing Mode in the form of a method called NAME specialized on
CPU returning an address according to BODY and a setf function to store to that
address. If CPU-REG is non-nil, BODY will be wrapped in a get-byte for setf. DOCS
is used as the documentation for the method and setf function when provided."
  `(progn
     (defgeneric ,name (cpu)
       (:documentation ,docs)
       (:method ((cpu cpu)) ,@body))
     (defun (setf ,name) (new-value cpu)
       ,docs
       ,(if cpu-reg
            `(setf ,@body new-value)
            `(let ((address (,name cpu)))
               (setf (get-byte address) new-value))))))

(defaddress implied () nil)

(defaddress accumulator (:cpu-reg t)
  (cpu-ar cpu))

(defaddress immediate (:cpu-reg t)
  (cpu-pc cpu))

(defaddress zero-page ()
  (get-byte (immediate cpu)))

(defaddress zero-page-x ()
  (wrap-byte (+ (zero-page cpu) (cpu-xr cpu))))

(defaddress zero-page-y ()
  (wrap-byte (+ (zero-page cpu) (cpu-yr cpu))))

(defaddress absolute ()
  (get-word (cpu-pc cpu)))

(defaddress absolute-x ()
  (let ((result (wrap-word (+ (absolute cpu) (cpu-xr cpu)))))
    (maybe-update-cycle-count cpu result)
    result))

(defaddress absolute-y ()
  (let ((result (wrap-word (+ (absolute cpu) (cpu-yr cpu)))))
    (maybe-update-cycle-count cpu result)
    result))

(defaddress indirect ()
  (get-word (absolute cpu)))

(defaddress indirect-x ()
  (get-word (wrap-byte (+ (zero-page cpu) (cpu-xr cpu))) t))

(defaddress indirect-y ()
  (let* ((addr (get-word (zero-page cpu) t))
         (result (wrap-word (+ addr (cpu-yr cpu)))))
    (maybe-update-cycle-count cpu result addr)
    result))

(defaddress relative ()
  (let ((addr (zero-page cpu))
        (result nil))
    (incf (cpu-cc cpu))
    (incf (cpu-pc cpu))
    (if (not (zerop (logand addr #x80)))
        (setf result (wrap-word (- (cpu-pc cpu) (logxor addr #xff) 1)))
        (setf result (wrap-word (+ (cpu-pc cpu) addr))))
    (maybe-update-cycle-count cpu result (cpu-pc cpu))
    result))

;;; Opcode Macrology

(defmacro defins ((name opcode cycle-count byte-count mode)
                  (&key setf-form (track-pc t)) &body body)
  "Define an EQL-Specialized method on OPCODE named NAME. MODE must return an
address or byte at an address if funcalled with a cpu. SETF-FORM is a lambda
that may be funcalled with a value to set the address computed by MODE. If
TRACK-PC is t, the default, the program counter will be incremented to just
past the instruction's operands. Otherwise, BODY is responsible for the PC."
  ;; KLUDGE: Why do I have to intern these symbols so they are created
  ;; in the correct package, i.e. the calling package rather than 6502-cpu?
  `(defmethod ,name ((,(intern "OPCODE") (eql ,opcode)) &key (cpu *cpu*)
                     (,(intern "MODE") ,mode) (,(intern "SETF-FORM") ,setf-form))
     ,@body
     ,@(when (and track-pc (> byte-count 1))
         `((incf (cpu-pc cpu) ,(1- byte-count))))
     (incf (cpu-cc cpu) ,cycle-count)
     cpu))

(defmacro defopcode (name (&key (docs "") raw (track-pc t)) modes &body body)
  "Define a Generic Function NAME with DOCS if provided and instructions,
i.e. methods, via DEFINS for each addressing mode listed in MODES. If RAW is
non-nil, MODE can be funcalled with a cpu in BODY to retrieve the byte at MODE's
address. Otherwise, funcalling MODE will return the computed address itself."
  (flet ((make-fetcher (mode)
           (let ((mode-name (alexandria:lastcar mode)))
             (substitute `(lambda (cpu) (get-byte (,(second mode-name) cpu)))
                         mode-name mode))))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel)
         (loop for (opcode cycles bytes mode) in ',modes
            do (setf (aref *opcodes* opcode)
                     (list ',name cycles bytes mode))))
       (defgeneric ,name (opcode &key cpu mode setf-form)
         (:documentation ,docs))
       ,@(mapcar (lambda (mode)
                   (let ((mode-name (second (alexandria:lastcar mode)))
                         (mode (if raw mode (make-fetcher mode))))
                     `(defins (,name ,@mode)
                          (:setf-form (lambda (x) (setf (,mode-name cpu) x))
                           :track-pc ,track-pc)
                        ,@body)))
                 modes))))
