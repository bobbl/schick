module Emit


// error codes
erBufferOverflow        = 100
erInvalidCharacter      = 101
erIdentifierExpected    = 103
erUnknownIdentifier     = 104
erFunctionRedefined     = 105
erTypeExpected          = 106


erBeginExpected         = 110 // of main routine
erStatementExpected     = 111
erNumberExpected        = 112 // for constant declaration
erBinaryStringExpected  = 113
erCompareOpExpected     = 114


// token from lexer
tkStringLiteral         = 1
tkIdentifier            = 31
tkNumericLiteral        = 94

tkProcedure             = 3
tkBegin                 = 4
tkEnd                   = 5
tkIf                    = 6
tkElse                  = 7
tkWhile                 = 8
tkReturn                = 9
tkAsm                   = 10
tkForward               = 11
tkByte                  = 12
tkNumber                = 13
tkString                = 14    // for assembly

tkComma                 = 44    // ','
tkDot                   = 46    // '.'
tkColon                 = 58    // ':'
tkSemicolon             = 59    // ';'
tkEqual                 = 80    // 'P' =
tkOpeningRoundBracket   = 40    // '('
tkClosingRoundBracket   = 41    // ')'
tkOpeningSquareBracket  = 91    // '['
tkClosingSquareBracket  = 93    // ']'

tkAssign                = 97    // 'a' :=
tkDots                  = 99    // 'c' ..


// symbol types
tyGlobalConstant        = 70    // 32 bit number
tyGlobalVariable        = 71
tyUndefinedProcedure    = 72
tyDefinedProcedure      = 73
tyLocalVariable         = 74    // or procedure parameter




/**********************************************************************
 * Syscalls
 **********************************************************************/

procedure PosixExit(ExitCode: number)
begin
  #asm
    .string ''9308D005  //    li a7, 93         # sys_exit
    .string ''73000000  //    ecall
  end
end

procedure PosixGetChar() : number
begin
  #asm
    .string ''1301C1FF  /*    add sp, sp, -4                    */
    .string ''13050000  /*    li a0, 0          # stdin         */
    .string ''93050100  /*    mv a1, sp         # buf on stack  */
    .string ''13061000  /*    li a2, 1          # 1 byte        */
    .string ''9308F003  /*    li a7, 63         # sys_read      */
    .string ''73000000  /*    ecall                             */
    .string ''93050500  /*    mv a1, a0         # return a0==0 ? -1 : (sp) */
    .string ''03450100  /*    lw a0, 0(sp)                      */
    .string ''13014100  /*    add sp, sp, 4                     */
    .string ''6344B000  /*    bgtz a1, $+4                      */
    .string ''1305F0FF  /*    li a0, -1                         */
  end
end

procedure BrkAlloc(Size: number) : []byte
begin
  #asm
    .string ''130141FF  /*    add sp, sp, -12                   */
    .string ''2324A100  /*    sw a0, 8(sp)      # size          */
    .string ''13050000  /*    li a0, 0                          */
    .string ''9308600D  /*    li a7, 214        # sys_brk       */
    .string ''73000000  /*    ecall                             */
    .string ''2320A100  /*    sw a0, 0(sp)      # end           */
    .string ''83288100  /*    lw a7, 8(sp)      # size          */
    .string ''33051501  /*    add a0, a0, a7                    */
    .string ''2322A100  /*    sw a0, 4(sp)      # end + size    */
    .string ''9308600D  /*    li a7, 214        # sys_brk       */
    .string ''73000000  /*    ecall                             */
    .string ''83284100  /*    lw a7, 4(sp)      # end + size    */

    .string ''93050500  //    mv a1, a0
    .string ''13050000  //    li a0, 0
    .string ''63941501  //    bne a1, a7, .+8
    .string ''03250100  //    lw a0, 0(sp)      # old end
    .string ''1301C100  // 1: add sp, sp, 12
  end
end

procedure PosixWrite(FileDesc: number, Buf: []byte, Len: number)
begin
  #asm
    .string ''93080004  //    li a7, 64         # sys_write
    .string ''73000000  //    ecall
  end
end

procedure PosixRead(FileDesc: number, Buf: []byte, Len: number)
begin
  #asm
    .string ''9308F003  //    li a7, 63         # sys_read
    .string ''73000000  //    ecall
  end
end





/**********************************************************************
 * Code generation for RV32IM
 **********************************************************************
 * Second attempt: fill and spill registers
 *
 * RISC-V Instruction Set Manual:
 * https://github.com/riscv/riscv-isa-manual/
 *
 * RISC-V ABI:
 * https://github.com/riscv-non-isa/riscv-elf-psabi-doc
 *
 * Register usage
 * --------------
 * x0        zero       fixed to
 * x1        ra         return address
 * x2        sp         stack pointer
 * x3        gp         pointer to global variables
 * x4        tp         (thread pointer)
 * x5 ... x7 t0 ... t2  expression stack
 * x8 ... x9 s0 ... s1  callee-saved local variables (including copy of parameters)
 * x10...x17 a0 ... a7  expression stack and function parameters
 * x18...x27 s2 ...s11  callee-saved local variables (including copy of parameters)
 * x28...x31 t3 ... t6  expression stack
 *
 * Memory map
 * ----------
 * 0x00010000 ELF header
 * 0x00010054 program entry point: call to main()
 * 0x00010068 function prologue/epilogue
 * 0x000100FC standard library functions
 *            compiled code
 * GP-0x0800  global variables
 * <GP+0x07FC end of ELF segment
 * ...
 * 0x7FFFFFC  end of stack
 **********************************************************************/


// instruction type
itPushImm12     = 8
itPushUImm32    = 10
itPushReg       = 11    // used as local variable
itPushMem       = 13    // used as global or local variable
itArithOp       = 14
    // 8...15 write into the destination register

  BufSize       : number        // total size of the buffer
  Buf           : []byte        // the buffer for everything
  CodePos       : number        // position in the buffer for code generation
  NumLocals     : number        // number of local variables in the current fuction
  NumGlobals    : number        // number of global variables

  RegPos        : number
  LastInsn      : number        // itXXX constants
  LastInsnType  : number        // itXXX constants

  ReturnList    : number
  MaxLocals     : number
  FunctionStartPos      : number
  LastBranchTarget      : number
    /* Position where the last branch points to.
       Used to determine the length of the last uninterrupted sequences of
       instructions. */
  NumScope      : number
  NumCalls      : number
  MaxRegPos     : number
  LocalReg      : []byte



// helper to write a 32 bit number to a char array
procedure SetBuf32(Addr: number, Value: number)
begin
  Buf[Addr  ] := Value
  Buf[Addr+1] := Value >> 8
  Buf[Addr+2] := Value >> 16
  Buf[Addr+3] := Value >> 24
end

// helper to read 32 bit number from a char array
procedure GetBuf32(Addr: number)
begin
  return Buf[Addr  ] +
        (Buf[Addr+1] << 8) +
        (Buf[Addr+2] << 16) +
        (Buf[Addr+3] << 24)
end

procedure EmitBinaryFunc(Len: number, Code: []byte)
begin
  CP : number := CodePos
  i  : number := 0
  while i < Len begin
    Buf[CP + i] := Code[i]
    i := i + 1
  end
  CodePos := CP + Len
  return CP
end

procedure Emit32(Insn: number)
begin
  CP : number  := CodePos
  CodePos      := CP + 4
  LastInsn     := Insn
  LastInsnType := 0
  SetBuf32(CP, Insn)
end

procedure EmitISDO(Imm: number, Rs: number, Rd: number, Opcode: number)
begin
  Emit32((Imm << 20) + (Rs << 15) + (Rd << 7) + Opcode)
end

// Same as EmitISDO(), but Rs=RegPos and if REG[RegPos] is loaded from a local
// variable in the previous instruction, fuse them.
procedure EmitIRDO(Imm: number, Rd: number, Opcode: number)
begin
  Rs : number := RegPos
  PrevInsn : number := GetBuf32(CodePos - 4)
  if (PrevInsn & 4293947519) = 19 begin
    //           0xFFF0707F) = 0x13      ADDI REG[RegPos], REG[RegPos], 0
    if ((PrevInsn >> 7) & 31) = RegPos begin // really necessary?
      // load local
      Rs := (PrevInsn >> 15) & 31
      CodePos := CodePos - 4
    end
  end
  EmitISDO(Imm, Rs, Rd, Opcode)
  LastInsnType := itArithOp
end

procedure InsnJAL(Rd: number, ImmJ: number)
begin
  return
    (((ImmJ>>20) & 1) << 31) |      // bit  31     = Imm[20]
    (((ImmJ & 2046  )        |      // bits 30..21 = Imm[10..1]
     ((ImmJ>>11) & 1))<< 20) |      // bit  20     = Imm[11]
    ((ImmJ & 1044480)      ) |      // bits 19..12 = Imm[19..12]
    ( Rd              <<  7) |      // bits 11..7  = Rd
    111;                            // bits  6..0  = 0x6f (jal)
end

procedure EmitPush()
begin
  RegPos := RegPos + 1
  if RegPos > MaxRegPos begin
    MaxRegPos := RegPos
  end
end

procedure EmitNumber(Imm: number)
begin
  if ((Imm + 2048) >> 12) = 0 begin
    EmitISDO(Imm, 0, RegPos, 19)
        // 00000013  ADDI REG[RegPos], X0, Imm
    LastInsnType := itPushImm12
  else
    Emit32((((Imm + 2048) >> 12) << 12) + (RegPos << 7) + 55)
        // 00000037  LUI REG[RegPos], Imm
    if (Imm << 20) <> 0 begin
      EmitISDO(Imm, RegPos, RegPos, 19)
        // 00000013  ADDI REG[RegPos], REG[RegPos], Imm
      LastInsnType := itPushUImm32
    end
  end
end


procedure EmitString(Len: number, s: []byte)
begin
  AlignedLen : number := (Len + 4) & 4294967292
    // there are 4 zero bytes appended to s
  Emit32(InsnJAL(RegPos, AlignedLen + 4))
    // JAL REG[RegPos], align(end_of_string)
  EmitBinaryFunc(Len, s)
  EmitBinaryFunc(AlignedLen - Len, ''00000000)
end

procedure EmitStore(Global: number, Ofs: number)
begin
  if Global = 0 begin
    if Ofs < 13 begin
      // max 13 local variables in registers
      if LastInsnType > 7 begin
        CodePos := CodePos - 4
        Emit32((LastInsn & 4294963327) | (LocalReg[Ofs] << 7))
          //               0xFFFFF07F
      else
        EmitISDO(0, RegPos, LocalReg[Ofs], 19)
          // ADDI REG[LocalReg[Ofs]], REG[RegPos], 0
      end
      return;
    end
    // otherwise fall back to stack
  end
  Emit32(73763 +
        (Global << 15) +
        (RegPos << 20) +
        ((Ofs & 1016   ) << 22) +       // bits 31..25 = ofs[9..3]
        ((Ofs & 7      ) <<  9))        // bits 11..7  = ofs[2..0] 0 0
    // SW REG[RegPos], (ofs+1)(REG[2+Global])
end

procedure EmitLoad(Global: number, Ofs: number)
begin
  if Global = 0 begin
    if Ofs < 13 begin
      // max 13 local variables in registers
      EmitISDO(0, LocalReg[Ofs], RegPos, 19)
        // ADDI REG[LocalReg[Ofs]], REG[RegPos], 0
      LastInsnType := itPushReg
      return;
    end
    // otherwise fall back to stack
  end
  EmitISDO(Ofs << 2, Global, RegPos, 73731)
    // LW REG[RegPos], Ofs(REG[2+Global])
  LastInsnType := itPushMem
end

opShiftL = 1
opShiftR = 2
opSub = 3
opOr  = 4
opXor = 5
opAdd = 6
opAnd = 7
opMul = 8
opDiv = 9
opRem = 10

procedure EmitOperation(Operation: number)
begin
/*
    1  << sll  00001033
    2  >> srl  00005033
    3  -  sub  40000033
    4  |  or   00006033
    5  ^  xor  00004033
    6  +  add  00000033
    7  &  and  00007033
    8  *  mul  02000033
    9  / divu  02005033
    10 % remu  02007033
*/
  Imm : number := RegPos
  RegPos := Imm - 1
  Shift : number := Operation + Operation + Operation - 3
  Op : number := (((1025264681 >> Shift) & 7) << 12) + 51
        /* octal: 75'0704'6051 */
  if Operation > 7 begin
    Op := Op + 33554432 // 0x0200'0000
  end
  if Operation = 3 begin
    Op := 1073741875 // 0x4000'0033
  end

  // code optimisation if second operand is a load from register */
  if LastInsnType = itPushReg begin
    Imm := (LastInsn >> 15) & 31
    CodePos := CodePos - 4
  end

  // code optimisation for constant immediates
  if Operation < 8 begin
    if (LastInsn & 1044607) = 19 begin
      //           0xFF07F  ADDI ?, X0, ?
      // register need not be checked
      // if (((last_insn & 1048575) == (19 + ((reg_pos + 11) << 7))) { */
      Imm := LastInsn >> 20;
      if Operation = 3 begin
        Imm := 0 - Imm
            /* 00000013  ADDI reg, reg, -imm
               imm is always positive, therefore -(-2048)=2048
               cannot happen */
      end
      CodePos := CodePos - 4
      Op := (((1854505 >> Shift) & 7) << 12) + 19;
        // octal: 704'6051
    end
  end
  EmitIRDO(Imm, RegPos, Op);
end

procedure EmitIndexPush(Global: number, Ofs: number)
begin
  EmitPush()
  EmitLoad(Global, Ofs)
  EmitOperation(opAdd)
  EmitPush()
  LastInsnType := itArithOp
end

procedure EmitPopStoreArray()
begin
  // RegPos is always 11 at this point
  RegPos := 10
  Emit32(11862051)
    // 00B50023  SB A1,0(A0)
end

procedure EmitIndexLoadArray(Global: number, Ofs: number)
begin
  Imm : number := 0
  Rs  : number := RegPos
  if LastInsnType = itPushImm12 begin
    Imm := LastInsn >> 20
    CodePos := CodePos - 4
    Rs := LocalReg[Ofs]

    // dublicate code because there is no logical or
    if Global <> 0 begin
      EmitLoad(Global, Ofs)
      Rs := RegPos
    else 
      if Ofs >= 13 begin
        EmitLoad(Global, Ofs)
        Rs := RegPos
      end
    end

  else
    EmitIndexPush(Global, Ofs)
    RegPos := RegPos - 1
  end
  EmitISDO(Imm, Rs, RegPos, 16387)
    // LBU REG[reg_pos], 0(REG[reg_pos])
end

// TODO: inline
procedure EmitPreWhile()
begin
  return CodePos
end

procedure EmitIf(Condition: number)
begin
  // at function entry RegPos is always 11
  Rs : number := 10
  Rt : number := 11

  // code optimisation if first operand is a local register
  PrevInsn : number := GetBuf32(CodePos - 8)
  if (PrevInsn & 4293951487) = 1299 begin
    //           0xfff07fff) = 0x513     ADDI A0, x?, 0
    Rs := (PrevInsn >> 15) & 31;
    CodePos := CodePos - 8
    Emit32(LastInsn)
  end

  // code optimisation if second operand is a local register
  if LastInsnType = itPushReg begin
    Rt := (LastInsn >> 15) & 31
    CodePos := CodePos - 4
  end

  // code optimisation if second operand is 0
  if LastInsn = 1427 begin // 00000593  ADDI A1, X0, 0
    Rt := 0
    CodePos := CodePos - 4
  end

    /* 0  00001063     BNE  s, t, +0    ==
       1  00000063     BEQ  s, t, +0    !=
       2  00007063     BGEU s, t, +0   <
       3  00006063     BLTU s, t, +0   >=
       4  00007063     BGEU t, s, +0   >
       5  00006063     BLTU t, s, +0   <= */
  if Condition > 3 begin
    h : number := Rs
    Rs := Rt
    Rt := h
    Condition := Condition - 2
  end
  Emit32((Rt << 20) |
         (Rs << 15) |
         ((Condition & 2) << 13) |
         (((Condition & 3) ^ 1) << 12) |
         99);
  RegPos := 10
  return CodePos - 4
end

procedure EmitThenEnd(InsnPos: number)
begin
  ImmB : number := CodePos - InsnPos
  ImmB := ((ImmB & 4096) << 19) |     // bit  31     = ImmB[12]
          ((ImmB & 2016) << 20) |     // bits 30..25 = ImmB[10..5]
          ((ImmB &   30) <<  7) |     // bits 11..8  = ImmB[4..1]
          ((ImmB & 2048) >>  4);      // bit  7      = ImmB[11]
  SetBuf32(InsnPos, (GetBuf32(InsnPos) & 33550463) | ImmB)
  LastBranchTarget := CodePos
end

procedure EmitElseEnd(InsnPos: number)
begin
  SetBuf32(InsnPos, InsnJAL(0, CodePos - InsnPos))
  LastBranchTarget := CodePos
end

procedure EmitThenElse(InsnPos: number) : number
begin
  Emit32(0)
  EmitThenEnd(InsnPos)
  return CodePos - 4
end

procedure EmitLoop(Destination: number, InsnPos: number)
begin
  Emit32(InsnJAL(0, Destination - CodePos))
  EmitThenEnd(InsnPos)
end

procedure EmitLocalVar(Init: number) : number
begin
  n : number := NumLocals + 1
  NumLocals := n
  if n > MaxLocals begin
    MaxLocals := n
  end
  if Init <> 0 begin // set initial value
    EmitStore(0, n)
  end
  return n
end

procedure EmitGlobalVar() : number
begin
  NumGlobals := NumGlobals + 1
  return NumGlobals - 513
end

procedure EmitPreCall() : number
begin
  // save expression stack it it is not empty
  r : number := RegPos
  if r > 10 begin
    // save currently used expression stack registers
    while RegPos > 10 begin
      RegPos := RegPos - 1
      EmitLocalVar(1)
    end
  end
  RegPos := 10
  return r
end

procedure EmitArg()
begin
  EmitPush()
end

procedure EmitCall(Ofs: number, Pop: number, Save: number)
begin
  r : number := CodePos
  Emit32(InsnJAL(1, Ofs - CodePos))
  NumCalls := NumCalls + 1

  if Save > 10 begin
    // restore previously saved expression stack registers
    Emit32((Save << 7) + 327699)
      // 000500513  MV REG[reg_pos], A0

    RegPos := 10
    while RegPos < Save begin
      EmitLoad(0, NumLocals)
      RegPos := RegPos + 1
      NumLocals := NumLocals - 1
    end
  end
  LastInsnType := 0 // avoid fusion with next instruction
  RegPos := Save
  return r
end

procedure EmitFixCall(From: number, To: number)
begin
  SetBuf32(From, InsnJAL(1, To - From))
end

procedure EmitFuncBegin(n: number)
begin
  CP0 : number := CodePos
  CP8 : number := CodePos + 8
  FunctionStartPos := CP0
  RegPos        := 10
  MaxRegPos     := 10
  NumLocals     := n
  MaxLocals     := n
  NumScope      := 0
  NumCalls      := 0
  ReturnList    := 0
  LastBranchTarget := CP8
  CodePos       := CP8
    // The first two instructions will be written by emit_func_end, when the
    // number of local variables is known.
  return CP0
end

procedure EmitReturn()
begin
  Emit32(ReturnList)
    // will be overwritten by a jump to the end of the function
  ReturnList := CodePos - 4
end

procedure EmitFuncEnd()
begin
  m : number := MaxLocals
    // Set stack reservation at start of function.
    // Stack pointer must be a multiple of 16.
    // Shift by 20 is an optimisation to save the imm field shift
  StackSize : number :=  ((m + 4) >> 2) << 24
  SetBuf32(FunctionStartPos, 65811 - StackSize)
    // 00010113  ADD SP, SP, 0-StackSize

  // entry to prologue depends on number of local variables
  Entry : number := 100 - FunctionStartPos
  if m < 9 begin
    Entry := Entry + 80 - (m << 3)
  else
    if m < 12 begin
      Entry := Entry + 48 - (m << 2)
    end
  end
  Entry := InsnJAL(5, Entry)
    // J _prologue
  SetBuf32(FunctionStartPos + 4, Entry)

  // go throught list of return statements
  CP : number := CodePos
  Next : number := ReturnList
  if Next = (CP - 4) begin
    // remove last jump to following instruction
    CP := CP - 4
    CodePos := CP
  end
  while Next <> 0begin
    Pos : number := Next
    Next := GetBuf32(Pos)
    SetBuf32(Pos, InsnJAL(0, CP - Pos))
  end

  // emit jump to epilogue
  Emit32(StackSize + 659)
    // 00000593  ADDI X5, X0, StackSize
  Emit32(InsnJAL(0, 236 - (m << 2) - CP))
    // J _epilogue + 4*(12-NumLocals)
end

procedure EmitScopeBegin() : number
begin
  NumScope := NumScope + 1
  return NumLocals
end

procedure EmitScopeEnd(Save: number)
begin
  NumLocals := Save
  NumScope := NumScope - 1
end

procedure EmitBegin() : number
begin
  CodePos := 0
  NumGlobals := 0
  LastBranchTarget := 0
  LocalReg := ' '080912131415161718191A1B
  EmitBinaryFunc(252, ''7F454C460101010000000000000000000200F300010000005400010034000000000000000000000034002000010000000000000001000000000000000000010000000100'........'07000000001000001300000013000000000000009368D005730000002328B1032326A103232491032322810323207103938B0800232E6101130B0800232C5101938A0700232A4101130A070023283101938906002326210113090600232491009384050023228100130405002320110067800200832D0103032DC102832C8102032C4102832B0102032BC101832A8101032A4101832901010329C1008324810003244100832001003301510067800000)
  
/*
elf_header:
    0000 7f 45 4c 46    e_ident         0x7F, "ELF"
    0004 01 01 01 00                    1, 1, 1, 0
    0008 00 00 00 00                    0, 0, 0, 0
    000C 00 00 00 00                    0, 0, 0, 0
    0010 02 00          e_type          2 (executable)
    0012 03 00          e_machine       0xF3 (RISC-V)
    0014 01 00 00 00    e_version       1
    0018 00 00 01 00    e_entry         0x00010000 + _start
    001C 34 00 00 00    e_phoff         program_header_table
    0020 00 00 00 00    e_shoff         0
    0024 00 00 00 00    e_flags         0
    0028 34 00          e_ehsize        52 (program_header_table)
    002A 20 00          e_phentsize     32 (start - program_header_table)
    002C 01 00          e_phnum         1
    002E 00 00          e_shentsize     0
    0030 00 00          e_shnum         0
    0032 00 00          e_shstrndx      0

program_header_table:
    0034 01 00 00 00    p_type          1 (load)
    0038 00 00 00 00    p_offset        0
    003C 00 80 04 08    p_vaddr         0x00010000 (default)
    0040 00 80 04 08    p_paddr         0x00010000 (default)
    0044 ?? ?? ?? ??    p_filesz
    0048 ?? ?? ?? ??    p_memsz
    004C 07 00 00 00    p_flags         7 (read, write, execute)
    0050 00 10 00 00    p_align         0x1000 (4 KiByte)

_start:
    0054 ?? ?? ?? ??                    set gp register
    0058 ?? ?? ?? ??
    005C 00 00 00 00    jal x1, _main
    0060 93 68 D0 05    or x17, x0, 93
    0064 73 00 00 00    ecall

_prologue:
    0068 23 28 b1 03    sw      s11,48(sp)
   4:   03a12623                sw      s10,44(sp)
   8:   03912423                sw      s9,40(sp)
   c:   03812223                sw      s8,36(sp)
  10:   03712023                sw      s7,32(sp)
  14:   00088b93                mv      s7,a7
  18:   01612e23                sw      s6,28(sp)
  1c:   00080b13                mv      s6,a6
  20:   01512c23                sw      s5,24(sp)
  24:   00078a93                mv      s5,a5
  28:   01412a23                sw      s4,20(sp)
  2c:   00070a13                mv      s4,a4
  30:   01312823                sw      s3,16(sp)
  34:   00068993                mv      s3,a3
  38:   01212623                sw      s2,12(sp)
  3c:   00060913                mv      s2,a2
  40:   00912423                sw      s1,8(sp)
  44:   00058493                mv      s1,a1
  48:   00812223                sw      s0,4(sp)
  4c:   00050413                mv      s0,a0
  50:   00112023                sw      ra,0(sp)
    00BC 67 80 02 00    jr      t0

_epilogue:
    00C0 83 2d 01 03    lw      s11,48(sp)
  5c:   02c12d03                lw      s10,44(sp)
  60:   02812c83                lw      s9,40(sp)
  64:   02412c03                lw      s8,36(sp)
  68:   02012b83                lw      s7,32(sp)
  6c:   01c12b03                lw      s6,28(sp)
  70:   01812a83                lw      s5,24(sp)
  74:   01412a03                lw      s4,20(sp)
  78:   01012983                lw      s3,16(sp)
  7c:   00c12903                lw      s2,12(sp)
  80:   00812483                lw      s1,8(sp)
  84:   00412403                lw      s0,4(sp)
  88:   00012083                lw      ra,0(sp)
  8c:   00510133                add     sp,sp,t0
    00F8 67 80 00 00    ret
*/

  return 92
    // return the address of the call to _main() as a forward reference
end

procedure EmitEnd() : number
begin
  Addr : number := CodePos + 1964 // 2048-84
  SetBuf32(84, (((Addr + 2048) >> 12) << 12) + 407)
    // 00000197  AUIPC GP, hi(Addr)
  SetBuf32(88, (Addr << 20) + 98707)
    // 00018193  ADDI GP, GP, lo(Addr)

  i : number := 0
  while i < NumGlobals begin
    Emit32(0)
    i := i + 1
  end

  SetBuf32(68, CodePos)
  SetBuf32(72, CodePos)
  return CodePos
end






/**********************************************************************
 * Scanner
 **********************************************************************/

DigitBuf16      : []byte
Ch              : number
ChClass         : number
LineNo          : number
Token           : number
TokenInt        : number
TokenSize       : number
TokenBuf        : []byte
SymsHead        : number


procedure PrintNumber(n: number)
begin
  if n = 0 begin
    PosixWrite(2, '0', 1)
  else
    x : number
    x := n
    i : number
    i := 16
    while x <> 0 begin
      i := i - 1
      DigitBuf16[i] := (x % 10) + 48 // +'0'
      x := x / 10
    end
    PosixWrite(2, DigitBuf16[i ..], 16 - i)
  end
end

procedure Error(ErrorNo: number)
begin
  PosixWrite(2, 'Error ', 6)
  PrintNumber(ErrorNo);
  PosixWrite(2, ' in line ', 9)
  PrintNumber(LineNo);
  PosixWrite(2, '.'0D0A, 3)
  PosixExit(ErrorNo)
end

procedure TokenCmp(Ident: []byte, Len: number) : number
begin
  i : number
  i := 0
  while Ident[i] = TokenBuf[i] begin
    i := i + 1
    if i = Len begin
      return 1;
    end
  end
  return 0;
end

procedure NextChar()
begin
  Ch := PosixGetChar()
  if Ch = 10 begin
    LineNo := LineNo + 1
  end
  ChClass := 32 /* ' ' */
  if Ch < 128 begin
    Classify : []byte
    Classify := '         ##  #                  #  _ JG!()HF,C.#^^^^^^^^^^:;RPT  __________________________[ ]E_ __________________________ D   '
      /*         012345678901234567890123456789012345678901234567890123456789
                           1         2         3         4         5
         ! = look at character for further processing
         # = whitespace (9, 10, 13, ' ', '/')
         ^ = digit [0123456789]
         _ = letter or underscore
        */
    ChClass := Classify[Ch]
  end
end

procedure StoreChar()
begin
  TokenBuf[TokenInt] := Ch
  TokenInt := TokenInt + 1
  if TokenInt >= TokenSize begin
    Error(erBufferOverflow)
  end
  Discard : number
  Discard := NextChar()
end

procedure GetToken()
begin
  i       : number
  Len     : number

  TokenSize := SymsHead - CodePos
  if TokenSize < 1024 begin
    Error(erBufferOverflow)
  end
  TokenSize := TokenSize - 512
  TokenBuf  := Buf[CodePos + 256 ..]
  TokenInt  := 0
  Token     := 0

  while ChClass = 35/* '#' */ begin // ch = 9,10,13,' ','/'
    if Ch = 47/* '/' */ begin
      NextChar()
      if Ch = 47/* '/' */ begin
        while Ch <> 10 begin
          NextChar()
        end
      else
        if Ch <> 42/* '*' */ begin
          Token := 73/* 'I' / */
          return;
        end
        NextChar()
        while Ch <> 47/* '/' */ begin
          while Ch <> 42/* '*' */ begin
            NextChar()
          end
          NextChar()
        end
      end
    end
    NextChar() 
  end

  if Ch > 255 begin
    return;
  end
  if ChClass = 32 begin
    Error(erInvalidCharacter)
  end

  Token := ChClass
  if Ch = 39/* ' */ begin

    while Ch = 39/* ' */ begin
      NextChar()
      while Ch <> 39/* ' */ begin
        StoreChar()
      end

      // hexadecimal pair appended?
      NextChar()
      i := 0
      while i < 16 begin
        if ChClass = 94/* ^ */ begin /* 0...9 */
          i := Ch - 48
        else
          if ChClass = 95/* _ */ begin /* A...F */
            i := Ch - 55
          else
            i := 16 // break out of loop
          end
        end
        if i < 16 begin
          NextChar()
          Len := Ch - 48
          if Len > 9 begin
            Len := Len - 7
          end
          Ch := (i << 4) + Len
          StoreChar()
        end
      end
    end

    Token := tkStringLiteral
  else
    if ChClass = 94/* ^ */ begin /* 0...9 */
      while ChClass = 94 begin
        TokenInt := (10 * TokenInt) + Ch - 48
        NextChar()
      end
      Token := tkNumericLiteral
    else
      if ChClass = 95/* _ */ begin /* letter or underscore */

        // store identifier in space between code and symbol table
        while (ChClass & 254) = 94 begin /* 94 or 95 */
          StoreChar()
        end
        TokenBuf[TokenInt] := 0

        // search keyword
        Keywords : []byte
        Keywords := '9procedure5begin3end2if4else5while6return4#asm8#forward4byte6number6string0'
        i := 0
        Len := 9 // same as first char in Keywords
        Token := 3
        while Len <> 0 begin
          if Len = TokenInt begin
            if TokenCmp(Keywords[i+1 ..], TokenInt) <> 0 begin
              return;
            end
          end
          Token := Token + 1
          i := i + Len + 1
          Len := Keywords[i] - 48
        end
        Token := tkIdentifier
      else
        if Ch = 60/* < */ begin
          NextChar()
          //Token := 82/* R < */
          if Ch = 60/* < */ begin
            NextChar()
            Token := 65/* A << */
          else
            if Ch = 61/* = */ begin
              NextChar()
              Token := 85/* U <= */
            else
              if Ch = 62/* > */ begin
                NextChar()
                Token := 81/* Q <> */
              end
            end
          end
        else
          if Ch = 62/* > */ begin
            NextChar()
            //Token := 84/* T < */
            if Ch = 61/* = */ begin
              NextChar()
              Token := 83/* S >= */
            else
              if Ch = 62/* > */ begin
                NextChar()
                Token := 66/* B >> */
              end
            end
          else
            if Ch = 58/* : */ begin
              NextChar()
              //Token := 58/* : */
              if Ch = 61/* = */ begin
                NextChar()
                Token := tkAssign // ':='
              end
            else
              if Ch = 46/* . */ begin
                NextChar()
                //Token := 46/* . */
                if Ch = 46/* . */ begin
                  NextChar()
                  Token := tkDots // '..'
                end
              else
                // case for ()+,-;=[]
                NextChar()
              end
            end
          end
        end
      end
    end
  end
end




/**********************************************************************
 * Symbol Management
 **********************************************************************/

procedure SymLookup() : number
begin
  if Token <> tkIdentifier begin
    Error(erIdentifierExpected)
  end
  Sym : number := SymsHead
  while Sym < BufSize begin
    Len : number := Buf[Sym + 5]
    if Len = TokenInt begin
      if TokenCmp(Buf[Sym+6 ..], Len) <> 0 begin
        return Sym
      end
    end
    Sym := Sym + Len + 6
  end
  return 0
end

procedure SymAppend(Addr: number, Type: number)
begin
  i : number := TokenInt
  SymsHead := SymsHead - TokenInt - 6
  s : number := SymsHead

  SetBuf32(s, Addr)
  Buf[s+4] := Type
  Buf[s+5] := i

  // copy backwards in case the token and the symbol table overlap
  while i <> 0 begin
    i := i - 1
    Buf[s+6+i] := TokenBuf[i]
  end
  GetToken()
end

procedure SymFix(Sym: number, FuncPos: number)
begin
  Addr : number := GetBuf32(Sym)

  if Buf[Sym+4] <> tyUndefinedProcedure begin
    Error(erFunctionRedefined)
  end

  while Addr <> 0 begin
    Next : number := GetBuf32(Addr)
    EmitFixCall(Addr, FuncPos)
    Addr := Next
  end
  SetBuf32(Sym, FuncPos)
  Buf[Sym+4] := tyDefinedProcedure
end





/**********************************************************************
 * Parser
 **********************************************************************/

procedure Accept(t: number) : number
begin
  if Token = t begin
    GetToken()
    return 1
  end
  return 0
end

procedure Expect(t: number)
begin
  if Accept(t) = 0 begin
    Error(200 + t) // Error: specific token expected
  end
end

procedure ExpectType()
begin
  if Accept(tkOpeningSquareBracket) <> 0 begin
    Expect(tkClosingSquareBracket)
    Expect(tkByte)
  else
    Expect(tkNumber)
  end
end

procedure ParseFactor() #forward

procedure ParseExpression()
begin
  ParseFactor()
  while (Token & 240) = 64 begin
    EmitPush()
    Op : number := Token & 15
    GetToken()
    ParseFactor()
    EmitOperation(Op)
  end
end

procedure ParseCondition() : number
begin
  ParseExpression()
  EmitPush()
  if (Token & 248) <> 80 begin
    Error(erCompareOpExpected)
  end
  Cond : number := Token & 15
  GetToken()
  ParseExpression()
  return EmitIf(Cond)
end

procedure ParseCall(Sym: number, Type: number, Ofs: number)
begin
  ParamNo : number := 0
  Save    : number := EmitPreCall()
  if Accept(tkClosingRoundBracket) = 0 begin
    ParseExpression()
    EmitArg()
    ParamNo := ParamNo + 1
    while Accept(tkComma) <> 0 begin
      ParseExpression()
      EmitArg()
      ParamNo := ParamNo + 1
    end
    Expect(tkClosingRoundBracket)
  end

  Link : number := EmitCall(Ofs, ParamNo, Save)
  if Type = tyUndefinedProcedure begin
    SetBuf32(Link, Ofs)
      // Overwrite the call to an undefined address with a link to the rest of
      // the linked list of calls to this not yet defined function
    SetBuf32(Sym, Link)
  end
end

procedure ParseFactor()
begin
  if Token = tkOpeningRoundBracket begin
    GetToken()
    ParseExpression()
    Expect(tkClosingRoundBracket)
    return;
  end
  if Token = tkNumericLiteral begin
    EmitNumber(TokenInt)
    GetToken()
    return;
  end
  if Token = tkStringLiteral begin
    EmitString(TokenInt, TokenBuf)
    GetToken()
    return;
  end

  if Token <> tkIdentifier begin
    Error(erIdentifierExpected)
  end
  Sym : number := SymLookup()
  if Sym = 0 begin
    Error(erUnknownIdentifier)
  end
  GetToken()
  Type : number := Buf[Sym + 4]
  Ofs : number := GetBuf32(Sym)

  if Accept(tkOpeningRoundBracket) <> 0 begin // '('
    ParseCall(Sym, Type, Ofs)
    return;
  end
  if Accept(tkOpeningSquareBracket) <> 0 begin // '['
    ParseExpression()
    if Accept(tkDots) <> 0 begin // '..'
      Expect(tkClosingSquareBracket)
      EmitPush()
      EmitLoad(Type & 1, Ofs)
      EmitOperation(opAdd)
    else
      Expect(tkClosingSquareBracket)
      EmitIndexLoadArray(Type & 1, Ofs)
    end
    return;
  end

  if Type = tyGlobalConstant begin // constant
    EmitNumber(Ofs)
  else // variable
    EmitLoad(Type & 1, Ofs)
  end
end

procedure ParseStatement() #forward

procedure ParseScope()
begin
  Scope : number := EmitScopeBegin()
  while Token <> tkEnd begin
    ParseStatement()
    Discard : number := Accept(tkSemicolon)
  end
  GetToken() // tkEnd
  EmitScopeEnd(Scope)
end

procedure ParseStatement()
begin
  if Accept(tkIf) <> 0 begin
    IfBranchPos : number := ParseCondition()
    Expect(tkBegin)
    Scope : number := EmitScopeBegin()
    while Token <> tkEnd begin
      if Accept(tkElse) <> 0 begin
        EmitScopeEnd(Scope)
        Scope := EmitThenElse(IfBranchPos)
        ParseScope()
        EmitElseEnd(Scope)
        return;
      end
      ParseStatement()
      Discard : number := Accept(tkSemicolon)
    end
    GetToken() // tkEnd
    EmitScopeEnd(Scope)
    EmitThenEnd(IfBranchPos)
    return;
  end

  if Accept(tkWhile) <> 0 begin
    LoopEntry : number := EmitPreWhile()
    ExitBranchPos : number := ParseCondition()
    Expect(tkBegin)
    ParseScope()
    EmitLoop(LoopEntry, ExitBranchPos)
    return;
  end

  if Accept(tkReturn) <> 0 begin
    if Accept(tkSemicolon) = 0 begin
      ParseExpression()
      Discard2 : number := Accept(tkSemicolon)
    end
    EmitReturn()
    return;
  end

  if Accept(tkAsm) <> 0 begin
    while Token <> tkEnd begin
      Expect(tkDot)
      Expect(tkString)
      if Token <> tkStringLiteral begin
        Error(erBinaryStringExpected)
      end
      EmitBinaryFunc(TokenInt, TokenBuf)
      GetToken() // tkStringLiteral
    end
    GetToken() // tkEnd
    return;
  end

  if Token <> tkIdentifier begin
    Error(erStatementExpected)
  end
  Sym : number := SymLookup()

  // declaration of variable
  if Sym = 0 begin
    // unknown identifier => must be declaration of variable
    SymAppend(0 /* don't care */, tyLocalVariable)
      // Add a local variable to the symbol table. Must be done before further
      // parsing, otherwise the name of the identifier in TokenBuf is lost.
      // But at this point the address is unknown and will be filled later with
      // SetBuf32()
    Expect(tkColon)
    ExpectType()
    if Accept(tkAssign) <> 0 begin
      ParseExpression()
      SetBuf32(SymsHead, EmitLocalVar(1))
    else
      SetBuf32(SymsHead, EmitLocalVar(0))
    end
    return;
  end

  Type : number := Buf[Sym + 4]
  Ofs  : number := GetBuf32(Sym)
  GetToken()

  // procedure call
  if Accept(tkOpeningRoundBracket) <> 0 begin
    ParseCall(Sym, Type, Ofs)
    return;
  end

  // assignment to array
  if Accept(tkOpeningSquareBracket) <> 0 begin
    ParseExpression()
    Expect(tkClosingSquareBracket)
    Expect(tkAssign)
    EmitIndexPush(Type & 1, Ofs)
    ParseExpression()
    EmitPopStoreArray()
    return;
  end

  // assignmnet to variable
  if Accept(tkAssign) <> 0 begin
    ParseExpression()
    EmitStore(Type & 1, Ofs)
    return;
  end

  // Declaration of variable, but identifier is already used.
  // Therefore cover the old declaration temporarily.
  if Token = tkColon begin
    // Fake the token buffer for sym_append(), because it was cleared when the
    // the following token ':' was parsed.
    TokenBuf := Buf[Sym+6 ..]
    TokenInt := Buf[Sym+5]
    SymAppend(EmitLocalVar(0), tyLocalVariable)
    ExpectType()
    return;
  end

  Error(erStatementExpected)
end

procedure ParseProcedure()
begin
  Sym : number := SymLookup()
  if Sym <> 0 begin
    GetToken()
  else
    SymAppend(0 /* don't care */, tyUndefinedProcedure)
    Sym := SymsHead
  end

  RestoreHead : number := SymsHead
  i : number := 0
  Expect(tkOpeningRoundBracket)
  while Accept(tkClosingRoundBracket) = 0 begin
    i := i + 1
    if Token = tkIdentifier begin
      SymAppend(i, tyLocalVariable) // parameters are local variables
      Expect(tkColon)
    end
    ExpectType()
    Discard : number := Accept(tkComma) // ignore trailing comma
  end

  if Accept(tkColon) <> 0 begin
    ExpectType()
  end

  if Accept(tkForward) = 0 begin
    Expect(tkBegin)
    SymFix(Sym, EmitFuncBegin(i))
    ParseScope()
    EmitFuncEnd()
  end
  SymsHead := RestoreHead // remove local variables from symbol table
end

procedure ParseDeclaration()
begin
  GetToken() // ignore keyword `module`
  GetToken() // ignore name of module
  Discard : number := Accept(tkSemicolon)

  while Accept(tkBegin) = 0 begin // while NOT begin
    if Token = tkIdentifier begin
      SymAppend(EmitGlobalVar(), tyGlobalVariable)
      if Accept(tkColon) <> 0 begin
        ExpectType()
      end
      if Accept(tkEqual) <> 0 begin
        if Token <> tkNumericLiteral begin
          Error(erNumberExpected)
        end
        Buf[SymsHead + 4] := tyGlobalConstant
        SetBuf32(SymsHead, TokenInt)
        GetToken()
      end
    else
      if Accept(tkProcedure) <> 0 begin
        ParseProcedure()
      else
        Error(erBeginExpected)
      end
    end
    Discard := Accept(tkSemicolon)
  end
end

procedure ParseMain()
begin
  ParseScope()
  Expect(tkDot)
end

begin
  BufSize       := 65536
  Buf           := BrkAlloc(BufSize + 16)
  SymsHead      := BufSize
  LineNo        := 1
  CodePos       := 0

  DigitBuf16    := Buf[BufSize ..]

  NextChar()
  GetToken()
  CallMain : number := EmitBegin()
  ParseDeclaration()
  EmitFixCall(CallMain, CodePos)
  ParseMain()
  Emit32(97544339)      // 93 68 D0 05  or x17, x0, 93
  Emit32(115);          // 73 00 00 00  ecall
  PosixWrite(1, Buf, EmitEnd())
end.
