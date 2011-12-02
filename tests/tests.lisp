(defpackage :6502-tests
  (:use :cl :6502 :fiveam)
  (:export #:run!))

(in-package :6502-tests)

(reset) ; Initialize the CPU.

;; Thanks to Michael Weber for a rough blueprint of shallow instance copying.
(defmacro with-cpu (&body body)
  "Store a copy of *CPU* and execute BODY in an unwind-protect which restores
the old value when BODY finishes."
  (alexandria:with-gensyms (backup slot slot-name)
    `(let ((,backup (allocate-instance (class-of *cpu*))))
       (dolist (,slot (closer-mop:class-slots (class-of *cpu*)))
         (let ((,slot-name (closer-mop:slot-definition-name ,slot)))
           (when (slot-boundp *cpu* ,slot-name)
             (setf (slot-value ,backup ,slot-name)
                   (slot-value *cpu* ,slot-name)))))
       ;; His original ran reinitialize-instance but we seem safe without it.
       (unwind-protect (progn ,@body)
         (setf *cpu* ,backup)))))

(def-suite :opcodes)
(in-suite :opcodes)

(test brk-sets-flags
  (with-cpu
    (brk #x00)
    (is (logbitp 4 (sr *cpu*)))
    (is (logbitp 2 (sr *cpu*)))))

(test brk-adds-24bits-to-stack
  ;; Program Counter (16) + Stack Pointer (8) == 24 bits
  ;; The stack is decremented from #xFF giving #xFC.
  (with-cpu
    (brk #x00)
    (is (= (sp *cpu*) #xfc))))
