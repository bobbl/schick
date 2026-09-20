module Emit

BaseAddr                = 65536 // 0001'0000hex base address from ELF header


// error codes
erBufferOverflow        = 100
erInvalidCharacter      = 101
erIdentifierExpected    = 103
erUnknownIdentifier     = 104
erFunctionRedefined     = 105
erTypeExpected          = 106


erDeclarationExpected   = 110 // of main routine
erStatementExpected     = 111
erConstantExpected      = 112 // for constant declaration
erBinaryStringExpected  = 113
erCompareOpExpected     = 114
erNonHexInString        = 115
er2ndHexDigitExpected   = 116

erUnreachable           = 199
erExpected              = 200




// symbol class
scGlobalConstant        = 70    // 32 bit number
scGlobalVariable        = 71
scUndefinedProcedure    = 72
scDefinedProcedure      = 73
scLocalVariable         = 74    // or procedure parameter
scType                  = 75




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

// return 0 if FileDesc is a TTY
procedure PosixNotATTY(FileDesc: number) : number
begin
  #asm
    // file descriptor is already in a0

    .string ''130101FC  // add sp, sp, -64      // memory for termios
    .string ''13060100  // mv a2, sp

    .string ''B7550000  // lui a1, 5
    .string ''93853541  // add a1, a1, 0x413
        // together: li a1, 0x5413 = TIOCGWINSZ
        //                           Terminal IO Control Get WINdow SiZe
        //                  0x5401 = TCGETS also works

    .string ''9308D001  // li a7, 29 # sys_ioctl
    .string ''73000000  // ecall

    .string ''13010104  // add sp, sp, 64
  end
end

procedure ColourWhite()
begin
  if PosixNotATTY(2) = 0 begin
    PosixWrite(2, ''1B'[1;37m', 7)
  end
end

procedure ColourBrightRed()
begin
  if PosixNotATTY(2) = 0 begin
    PosixWrite(2, ''1B'[1;31m', 7)
  end
end

procedure ColourBrightGreen()
begin
  if PosixNotATTY(2) = 0 begin
    PosixWrite(2, ''1B'[1;32m', 7)
  end
end

procedure ColourBack()
begin
  if PosixNotATTY(2) = 0 begin
    PosixWrite(2, ''1B'[0m', 4)
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
itComparison    = 15
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

procedure EmitStore(SymClass: number, Ofs: number)
begin
  if SymClass = scLocalVariable begin
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
      return
    end
    // otherwise fall back to stack
  end
  Emit32(73763 +
        ((SymClass & 1) << 15) +
        (RegPos << 20) +
        ((Ofs & 1016   ) << 22) +       // bits 31..25 = ofs[9..3]
        ((Ofs & 7      ) <<  9))        // bits 11..7  = ofs[2..0] 0 0
    // SW REG[RegPos], (ofs+1)(REG[2+Global])
end

procedure EmitLoad(SymClass: number, Ofs: number)
begin
  if SymClass = scGlobalConstant begin
    EmitNumber(Ofs)
    return
  end

  if SymClass = scLocalVariable begin
    if Ofs < 13 begin
      // max 13 local variables in registers
      EmitISDO(0, LocalReg[Ofs], RegPos, 19)
        // ADDI REG[LocalReg[Ofs]], REG[RegPos], 0
      LastInsnType := itPushReg
      return
    end
    // otherwise fall back to stack
  end
  EmitISDO(Ofs << 2, SymClass & 1, RegPos, 73731)
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

procedure EmitComp(Condition: number)
begin
  RegPos := RegPos - 1
  if Condition < 2 begin
    if (LastInsn & 4294963327) = 19 begin
      //           0xFFFFF07F optimization if compared with 0
      CodePos := CodePos - 4
    else
      EmitISDO(RegPos, RegPos, RegPos, 1074790451)
        // sub REG, REG, REG+1
    end
    if Condition = 0 begin
      EmitISDO(0, RegPos, RegPos, 1060883)
        // sltiu REG, REG, 1        ==
    else
      EmitISDO(RegPos, 0, RegPos, 12339)
        // sltu REG, x0, REG        !=
    end
  else
    o : number := 45107
      // 0000B033  sltu REG, REG+1, REG     > or <= */
    if Condition < 4 begin
      o := 1060915
        // 00103033  sltu REG, REG, REG+1     < or >= 
    end
    EmitISDO(RegPos, RegPos, RegPos, o)
    if (Condition & 1) <> 0 begin
      EmitISDO(0, RegPos, RegPos, 1064979)
        // xori REG, REG, 1         >= or <=
    end
  end
  LastInsnType := itComparison
end

procedure EmitIndexPush(SymClass: number, Ofs: number)
begin
  EmitPush()
  EmitLoad(SymClass, Ofs)
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

procedure EmitIndexLoadArray(SymClass: number, Ofs: number)
begin
  Imm : number := 0
  Rs  : number := RegPos
  if LastInsnType = itPushImm12 begin
    Imm := LastInsn >> 20
    CodePos := CodePos - 4
    Rs := LocalReg[Ofs]

    // dublicate code because there is no logical or
    if SymClass <> scLocalVariable begin
      EmitLoad(SymClass, Ofs)
      Rs := RegPos
    else
      if Ofs >= 13 begin
        EmitLoad(SymClass, Ofs)
        Rs := RegPos
      end
    end

  else
    EmitIndexPush(SymClass, Ofs)
    RegPos := RegPos - 1
  end
  EmitISDO(Imm, Rs, RegPos, 16387)
    // LBU REG[RegPos], 0(REG[RegPos])
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
    EmitStore(scLocalVariable, n)
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

procedure EmitCall(Ofs: number, Pop: number, Save: number) : number
begin
  r : number := CodePos
  Emit32(InsnJAL(1, Ofs - CodePos))
  NumCalls := NumCalls + 1

  if Save > 10 begin
    // restore previously saved expression stack registers
    Emit32((Save << 7) + 327699)
      // 000500513  MV REG[RegPos], A0

    RegPos := 10
    while RegPos < Save begin
      EmitLoad(scLocalVariable, NumLocals)
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

//                                               !"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~ '
ClassifyChar = '         !!  !                  !  ~ JG"<="F9""!||||||||||";"P"? }}}}}}~~~~~~~~~~~~~~~~~~~~> ?E~ }}}}}}~~~~~~~~~~~~~~~~~~~~ D ~ '

// The chars '0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ' in ClassifyChar are
// converted to Tokens 0 ... 52
// The other chars belong to a character class:

ccInvalidChar   = 32    // ' '
ccWhitespace    = 33    // '!'    9, 10, 13, ' ', '/'
ccMultiChar     = 34    // '"'
ccDigit         = 124   // '|'    '0' ... '9'
ccHexLetter     = 125   // '}'    'A' ... 'F', 'a' ... 'f'
ccLetter        = 126   // '~'    '#', 'G' ... 'Z', '_', 'g' ... 'z'



// token from lexer
tkEOF           = 0
tkIdentifier    = 1
tkStringLiteral = 2
tkIntegerLiteral= 3

DelimiterList   = '. , : ; ( ) [ ] UNUSED << >> - | ^ + & * / % UNUSED := -> .. ** = <> < >= > <= UNUSED UNUSED'

                        // char in ClassifyChar, char in input stream
tkDot           = 8     //     .
tkComma         = 9     // '9' ,
tkColon         = 10    //     :
tkSemicolon     = 11    // ';' ;
tkOpenRound     = 12    // '<' (
tkCloseRound    = 13    // '=' )
tkOpenSquare    = 14    // '>' [
tkCloseSquare   = 15    // '?' ]

tkShiftL        = 17    //     <<
tkShiftR        = 18    //     >>
tkMinus         = 19    // 'C' -
tkOr            = 20    // 'D' |
tkXor           = 21    // 'E' ^
tkPlus          = 22    // 'F' +
tkAnd           = 23    // 'G' &
tkMul           = 24    //     *
tkDiv           = 25    //     /
tkMod           = 26    // 'J' %

tkAssign        = 28    //     :=
tkArrow         = 29    //     ->
tkDots          = 30    //     ..
tkPower         = 31    //     **

tkEQ            = 32    // 'P' =
tkNE            = 33    //     <>
tkLT            = 34    //     <
tkGE            = 35    //     >=
tkGT            = 36    //     >
tkLE            = 37    //     <=

tkKeyword       = 40



KeywordList  = 'if end for nil var #asm .... .... elif else .... true type #goto #pure begin break const false until while #label import module ...... return string #packed #public #discard #forward continue procedure'
KeywordOfs   = '..'0003133B6B95A5C0CA
KeywordToken = '..'0001050D151B1D2021

// token          value                            keyword       offset
tkIf            = 40   // = tkKeyword + 0         // if           00 KeywordOfs[2]

tkEnd           = 41   // = tkKeyword + 1         // end          03 KeywordOfs[3]
tkFor           = 42   // = tkKeyword + 2         // for          07
tkNil           = 43   // = tkKeyword + 3         // nil          0B
tkVar           = 44   // = tkKeyword + 4         // var          0F

tkAsm           = 45   // = tkKeyword + 5         // #asm         13 KeywordOfs[4]
//tkByte          = 46   // = tkKeyword + 6         // byte         18
//tkChar          = 47   // = tkKeyword + 7         // char         1D
tkElif          = 48   // = tkKeyword + 8         // elif         22
tkElse          = 49   // = tkKeyword + 9         // else         27
//tkReal          = 50   // = tkKeyword + 10        // real         2C
tkTrue          = 51   // = tkKeyword + 11        // true         31
tkType          = 52   // = tkKeyword + 12        // type         36

tkGoto          = 53   // = tkKeyword + 13        // #goto        3B KeywordOfs[5]
tkPure          = 54   // = tkKeyword + 14        // #pure        41
tkBegin         = 55   // = tkKeyword + 15        // begin        47
tkBreak         = 56   // = tkKeyword + 16        // break        4D
tkConst         = 57   // = tkKeyword + 17        // const        53
tkFalse         = 58   // = tkKeyword + 18        // false        59
tkUntil         = 59   // = tkKeyword + 19        // until        5F
tkWhile         = 60   // = tkKeyword + 20        // while        65

tkLabel         = 61   // = tkKeyword + 21        // #label       6B KeywordOfs[6]
tkImport        = 62   // = tkKeyword + 22        // import       72
tkModule        = 63   // = tkKeyword + 23        // module       79
//tkNumber        = 64   // = tkKeyword + 24        // number       80
tkReturn        = 65   // = tkKeyword + 25        // return       87
tkString        = 66   // = tkKeyword + 26        // string       8E

tkPacked        = 67   // = tkKeyword + 27        // #packed      95 KeywordOfs[7]
tkPublic        = 68   // = tkKeyword + 28        // #public      9D

tkDiscard       = 69   // = tkKeyword + 29        // #discard     A5 KeywordOfs[8]
tkForward       = 70   // = tkKeyword + 30        // #forward     AE
tkContinue      = 71   // = tkKeyword + 31        // continue     B7

tkProcedure     = 72   // = tkKeyword + 32        // procedure    C0 KeywordOfs[9]




LineBufSize     = 1024

DigitBuf16      : []byte
Ch              : number
ChClass         : number
LineNo          : number
LineCol         : number
LineLastCol     : number
LineBuf         : []byte
Token           : number
TokenInt        : number
TokenSize       : number
TokenBuf        : []byte
SymsHead        : number
StackHead       : number


procedure PrintNumber(n: number, Fill: number)
begin
  i : number
  if n = 0 begin
    i := 15
    DigitBuf16[15] := '0'
  else
    x : number
    x := n
    i := 16
    while x <> 0 begin
      i := i - 1
      DigitBuf16[i] := (x % 10) + 48 // +'0'
      x := x / 10
    end
  end
  while 16 - i < Fill begin
    i := i - 1
    DigitBuf16[i] := 32 // ' '
  end
  PosixWrite(2, DigitBuf16[i ..], 16 - i)
end

procedure PrintFromList(n: number, List: []byte)
begin
  i : number := 0
  while n <> 0 begin
    while List[i] <> 32 begin
      i := i + 1
    end
    i := i + 1
    n := n - 1
  end
  j : number := i
  while List[j] <> 32 begin
    j := j + 1
  end
  PosixWrite(2, List[i ..], j-i)
end

procedure NextChar()
begin
  Ch := PosixGetChar()
  if Ch = 10 begin
    LineNo := LineNo + 1
    LineLastCol := LineCol // if faulty token is directly followed by a newline
    LineCol := 0
  else
    if LineCol < LineBufSize begin
      LineBuf[LineCol] := Ch
    end
    LineCol := LineCol + 1
  end
end

procedure ErrorMsg(e: number)
begin
  if e >= erExpected begin
    PosixWrite(2, '`', 1)
    t : number := e - erExpected
    if t >= tkDot begin
      if t < tkKeyword begin
        PrintFromList(t - tkDot, DelimiterList)
      else
        PrintFromList(t - tkKeyword, KeywordList)
      end
      PosixWrite(2, '` expected', 12)
      return
    end
  end

  if e=erBufferOverflow         begin PosixWrite(2, 'buffer overflow', 15) return end
  if e=erInvalidCharacter       begin
    PosixWrite(2, 'invalid character no. ', 22)
    PrintNumber(Ch, 0)
    return 
  end
  if e=erIdentifierExpected     begin PosixWrite(2, 'identifier expected', 19) return end
  if e=erUnknownIdentifier      begin PosixWrite(2, 'unknown identifier', 18) return end
  if e=erFunctionRedefined      begin PosixWrite(2, 'function redefined', 18) return end
  if e=erTypeExpected           begin PosixWrite(2, 'type expected', 13) return end
  if e=erDeclarationExpected    begin PosixWrite(2, 'declaration expected', 20) return end
  if e=erStatementExpected      begin PosixWrite(2, 'statement expected', 18) return end
  if e=erConstantExpected       begin PosixWrite(2, 'constant value expected', 23) return end
  if e=erBinaryStringExpected   begin PosixWrite(2, 'binary string expected', 22) return end
  if e=erNonHexInString         begin PosixWrite(2, 'invalid letter in hexadecimal string', 34) return end
  if e=er2ndHexDigitExpected    begin PosixWrite(2, 'second hex digit expected at end of hexadecimal string', 54) return end
  if e=erUnreachable            begin PosixWrite(2, 'internal error: unreachable', 27) return end
  //if e=er begin PosixWrite(2, '', ) return end

  PrintNumber(e, 0)
end

procedure Error(ErrorNo: number)
begin
  if LineCol = 0 begin
    // newline after last token => restore previous line
    LineCol := LineLastCol + 1
    LineNo := LineNo - 1
  end

  ErrorCol : number := LineCol - 1
  if Token = tkIdentifier begin
    ErrorCol := ErrorCol - TokenInt
  else 
    if Token >= tkKeyword begin
      ErrorCol := ErrorCol - TokenInt
    else
      ErrorCol := ErrorCol - 1
    end
  end

  ColourWhite()
  PosixWrite(2, 'stdin', 5)
  PosixWrite(2, ':', 1)
  PrintNumber(LineNo, 0);
  PosixWrite(2, ':', 1)
  PrintNumber(LineCol, 0);
  ColourBrightRed()
  PosixWrite(2, ' error E', 8)
  PrintNumber(ErrorNo, 0)
  PosixWrite(2, ': ', 2)
  ColourBack()
  ErrorMsg(ErrorNo)
  PosixWrite(2, ''0D0A, 2)
  PrintNumber(LineNo, 5);
  PosixWrite(2, ' | ', 3)

  // read and print rest of line
  LineLen : number := LineCol
  while Ch <> 10 begin
    LineLen := LineLen + 1
    NextChar()
    if Ch > 255 begin
      Ch := 10
    end
  end
  if LineLen > LineBufSize begin
    LineLen := LineBufSize + 1
  end
  PosixWrite(2, LineBuf, LineLen - 1)

  // point to column in line
  PosixWrite(2, ''0D0A'      | ', 10)
  i : number := 0
  while i < ErrorCol begin
    LineBuf[i] := 32 // ' '
    i := i + 1
  end
  PosixWrite(2, LineBuf, ErrorCol)
  ColourBrightGreen()
  PosixWrite(2, '^'0D0A, 3)
  ColourBack()
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

procedure ReturnToken() : number
begin
  TokenSize := SymsHead - CodePos
  if TokenSize < 1024 begin
    Error(erBufferOverflow)
  end
  TokenSize := TokenSize - 512
  TokenBuf  := Buf[CodePos + 256 ..]
  TokenInt  := 0

  if Ch > 128 begin
    LineCol := LineCol + 1
    Error(erInvalidCharacter)
  end
  Class : number := ClassifyChar[Ch]

  // ignore whitespace and comments
  while Class = ccWhitespace begin // ch = 9,10,13,' ','/'
    if Ch = 47/* '/' */ begin
      NextChar()
      if Ch = 47/* '/' */ begin
        while Ch <> 10 begin
          NextChar()
        end
      else
        if Ch <> 42/* '*' */ begin
          return tkDiv
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
    Class := ClassifyChar[Ch]
  end

  if Ch > 255 begin
    return tkEOF;
  end
  if Class = ccInvalidChar begin
    LineCol := LineCol + 1
    Error(erInvalidCharacter)
  end

  // numeric literal
  if Class = ccDigit begin // 0...9
    while Class = ccDigit begin
      TokenInt := (10 * TokenInt) + Ch - 48
      NextChar()
      Class := ClassifyChar[Ch]
    end
    return tkIntegerLiteral
  end

  // identifier or keyword
  if Class >= ccHexLetter begin // ccHexLetter or ccLetter (incl. `_` and `#`)

    // store identifier in space between code and symbol table
    while Class >= ccDigit begin // ccDigit or ccLetter
      StoreChar()
      Class := ClassifyChar[Ch]
    end
    TokenBuf[TokenInt] := 0

    // keywords have length 2 (if) ... 9 (procedure)
    Len : number := TokenInt
    if Len < 2 begin
      return tkIdentifier
    end
    if Len > 9 begin
      return tkIdentifier
    end

    // search keyword
    Ofs    : number := KeywordOfs[Len]
      // index in KeywordList with the first keyword of this length
    OfsEnd : number := KeywordOfs[Len+1]
      // index of next length is the end of keywords with this length
    t      : number := KeywordToken[Len] + tkKeyword
      // token for the first keyword of this length
    while Ofs < OfsEnd begin
      if TokenCmp(KeywordList[Ofs ..], Len) <> 0 begin
        return t
      end
      Ofs := Ofs + Len + 1      // next word
      t := t + 1                // next token number
    end
    return tkIdentifier
  end

  // string literal
  if Ch = 39/* ' */ begin
    while Ch = 39/* ' */ begin
      NextChar()
      while Ch <> 39/* ' */ begin
        StoreChar()
      end

      // hexadecimal pairs appended?
      NextChar()
      HiNibble : number := 0
      while HiNibble < 16 begin
        Class := ClassifyChar[Ch]
        if Class = ccDigit begin // 0...9
          HiNibble := Ch - 48
        else
          if Class = ccHexLetter begin // A...F a...f
            HiNibble := (Ch & 31) + 9
          else
            if Class = ccLetter begin
              Error(erNonHexInString)
            end
            HiNibble := 16 // break out of loop
          end
        end
        if HiNibble < 16 begin
          NextChar()
          Class := ClassifyChar[Ch]
          LoNibble : number
          if Class = ccDigit begin // 0...9
            LoNibble := Ch - 48
          else
            if Class = ccHexLetter begin // A...F a...f
              LoNibble := (Ch & 31) + 9
            else
              Error(er2ndHexDigitExpected)
            end
          end
          Ch := (HiNibble << 4) + LoNibble
          StoreChar()
        end
      end
    end
    return tkStringLiteral
  end

  // single char delimiter
  if Class <> ccMultiChar begin
    NextChar()
    return Class - 48 
  end

  // remaining: possible multi char delimiter
  if Ch = 42/* * */ begin
    NextChar()
    if Ch = 42/* * */ begin
      NextChar()
      return tkPower
    end
    return tkMul
  end

  if Ch = 45/* - */ begin
    NextChar()
    if Ch = 62/* > */ begin
      NextChar()
      return tkArrow
    end
    return tkMinus
  end

  if Ch = 46/* . */ begin
    NextChar()
    if Ch = 46/* . */ begin
      NextChar()
      return tkDots
    end
    return tkDot
  end

  if Ch = 58/* : */ begin
    NextChar()
    if Ch = 61/* = */ begin
      NextChar()
      return tkAssign
    end
    return tkColon
  end

  if Ch = 60/* < */ begin
    NextChar()
    if Ch = 60/* < */ begin
      NextChar()
      return tkShiftL
    end
    if Ch = 61/* = */ begin
      NextChar()
      return tkLE
    end
    if Ch = 62/* > */ begin
      NextChar()
      return tkNE
    end
    return tkLT
  end

  if Ch = 62/* > */ begin
    NextChar()
    if Ch = 61/* = */ begin
      NextChar()
      return tkGE
    end
    if Ch = 62/* > */ begin
      NextChar()
      return tkShiftR
    end
    return tkGT
  end

  Error(erUnreachable)
end

procedure GetToken()
begin
  Token := ReturnToken()
//  PrintNumber(Token, 5)
end





/**********************************************************************
 * Symbol Management
 **********************************************************************

The object stack grows from the highest address in Buf downwards and contains
two different kind of objects: symbols and types

SymsHead  first symbol
StackHead current stack position (<>SymsHead if types were added recently)

Symbol
------
0...3   Next (index in Buf)
4...7   Addr                    scConst: constant value
8...11  Type (index in Buf)     scModule: SubSymbols
12      Class
13      NameLen
14...   NameStr

Type
----
        tfSubRange tfEnum  tfRecord tfPointer tfArray  tfProcedure
0...3   Low        SymList SymList  -         Length   ParamList
4...7   High       -       -        BaseType  BaseType ReturnType (can be a record)
8...11  size in bytes
12      Form

 **********************************************************************/

// form of a type
tfBoolean       = 1
tfByte          = 3
tfUInt16        = 4
tfNumber        = 5
tfUInt64        = 6
tfUInt128       = 7
tfInt8          = 11
tfInt16         = 12
tfInt32         = 13
tfInt64         = 14
tfInt128        = 15
tfFloat32       = 21
tfReal          = 22
tfFloat128      = 23

tfSubRange      = 24    // low, high
tfEnum          = 25    // list of symbols (without type)
tfRecord        = 26    // list of symbols (with type)
tfPointer       = 27    // base type
tfVarArray      = 28    // base type
tfArray         = 29    // base type, length
tfProcedure     = 30    // list of param types, list of return types

procedure SymLookup() : number
begin
  if Token <> tkIdentifier begin
    Error(erIdentifierExpected)
  end
  Sym : number := SymsHead
  while Sym < BufSize begin
    Len : number := Buf[Sym + 13]
    if Len = TokenInt begin
      if TokenCmp(Buf[Sym + 14 ..], Len) <> 0 begin
        return Sym
      end
    end
    Sym := GetBuf32(Sym) // next list entry
  end
  return 0
end

procedure SymAppend(Addr: number, SymClass: number) : number
begin
  i : number := TokenInt
  NewSym : number := (StackHead - TokenInt - 14) & 4294967292 /* ~3 align to 32 bit */
  StackHead := NewSym

  SetBuf32(NewSym,     SymsHead)
  SetBuf32(NewSym + 4, Addr)
  //SetBuf32(NewSym + 8, TypePtr)
  Buf[NewSym + 12] := SymClass
  Buf[NewSym + 13] := i

  // copy backwards in case the token and the symbol table overlap
  while i <> 0 begin
    i := i - 1
    Buf[NewSym + 14 + i] := TokenBuf[i]
  end
  SymsHead := NewSym

  GetToken()
  return NewSym
end

procedure SymFix(Sym: number, FuncPos: number)
begin
  Addr : number := GetBuf32(Sym + 4)

  if Buf[Sym + 12] <> scUndefinedProcedure begin
    Error(erFunctionRedefined) // move cursor back one token to tkIdentifier
  end

  while Addr <> 0 begin
    Next : number := GetBuf32(Addr)
    EmitFixCall(Addr, FuncPos)
    Addr := Next
  end
  SetBuf32(Sym + 4, FuncPos)
  Buf[Sym + 12] := scDefinedProcedure
end

procedure SymSetClassAddr(Sym: number, SymClass: number, Addr: number)
begin
  Buf[Sym + 12] := SymClass
  SetBuf32(Sym + 4, Addr)
end

// add a type to the sympol table and return its index in Buf
procedure TypeAppend(Form: number, SymList: number, BaseType: number, Size: number) : number
begin
  r : number := (StackHead - 16) & 4294967292 /* ~3 align to 32 bit*/
  StackHead := r
  SetBuf32(r, SymList)
  SetBuf32(r + 4, BaseType)
  SetBuf32(r + 8, Size)
  Buf[r + 12] := Form
  return r
end

procedure TypeSymAppend(Name: []byte, Len: number, Form: number)
begin
  Type   : number := TypeAppend(Form, 0, 0, 0, 0)
  NewSym : number := (StackHead - Len - 14) & 4294967292 /* ~3 align to 32 bit */
  StackHead := NewSym

  SetBuf32(NewSym,     SymsHead)
  SetBuf32(NewSym + 4, 0 /* don't care for type */)
  SetBuf32(NewSym + 8, Type)
  Buf[NewSym + 12] := scType
  Buf[NewSym + 13] := Len

  i : number := 0
  while i < Len begin
    Buf[NewSym + 14 + i] := Name[i]
    i := i + 1
  end
  SymsHead := NewSym
end

procedure SymInit()
begin
  TypeSymAppend('boolean', 7, tfBoolean)
  TypeSymAppend('byte', 4, tfByte)
  TypeSymAppend('number', 6, tfNumber)
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
    Error(erExpected + t) // Error: specific token expected
  end
end

procedure ParseFactor() #forward

// return 0 if t is not an operator token


procedure IsOperator(t: number) : number
begin
  if Token < tkShiftL begin
    return 0
  end
  if Token > tkMod begin
    return 0
  end
  return 1
end

procedure IsRelation(t: number) : number
begin
  if Token < tkEQ begin
    return 0
  end
  if Token > tkLE begin
    return 0
  end
  return 1
end

procedure ParseOperation()
begin
  ParseFactor()
  while IsOperator(Token) <> 0 begin
    EmitPush()
    Op : number := Token & 15
    GetToken()
    ParseFactor()
    EmitOperation(Op)
  end
end

procedure ParseExpression()
begin
  ParseOperation()
  while IsRelation(Token) <> 0 begin
    EmitPush()
    Op : number := Token & 15
    GetToken()
    ParseOperation()
    EmitComp(Op)
  end
end

procedure ParseCondition() : number
begin
  ParseOperation()
  EmitPush()
  if (Token & 248) = 32 begin
    Cond : number := Token & 15
    GetToken()
    ParseOperation()
    return EmitIf(Cond);
  else
    // DIRTY: implicit "<> 0" to cover `|` and `&` on boolean expressions
    EmitNumber(0);
    return EmitIf(1);
  end
end

procedure ParseCall(Sym: number, SymClass: number, Ofs: number)
begin
  ParamNo : number := 0
  Save    : number := EmitPreCall()
  if Accept(tkCloseRound) = 0 begin
    ParseExpression()
    EmitArg()
    ParamNo := ParamNo + 1
    while Accept(tkComma) <> 0 begin
      ParseExpression()
      EmitArg()
      ParamNo := ParamNo + 1
    end
    Expect(tkCloseRound)
  end

  Link : number := EmitCall(Ofs, ParamNo, Save)
  if SymClass = scUndefinedProcedure begin
    SetBuf32(Link, Ofs)
      // Overwrite the call to an undefined address with a link to the rest of
      // the linked list of calls to this not yet defined function
    SetBuf32(Sym + 4, Link)
  end
end

procedure ParseFactor()
begin
  if Token = tkOpenRound begin
    GetToken()
    ParseExpression()
    Expect(tkCloseRound)
    return
  end
  if Token = tkIntegerLiteral begin
    EmitNumber(TokenInt)
    GetToken()
    return
  end
  if Token = tkStringLiteral begin
    EmitString(TokenInt, TokenBuf)
    GetToken()
    return
  end
  if Token = tkFalse begin
    EmitNumber(0)
    GetToken()
    return
  end
  if Token = tkTrue begin
    EmitNumber(1)
    GetToken()
    return
  end

  if Token <> tkIdentifier begin
    Error(erIdentifierExpected)
  end
  Sym : number := SymLookup()
  if Sym = 0 begin
    Error(erUnknownIdentifier)
  end
  GetToken()
  SymClass : number := Buf[Sym + 12]
  Ofs : number := GetBuf32(Sym + 4)

  if Accept(tkOpenRound) <> 0 begin // '('
    ParseCall(Sym, SymClass, Ofs)
    return
  end
  if Accept(tkOpenSquare) <> 0 begin // '['
    ParseExpression()
    if Accept(tkDots) <> 0 begin // '..'
      Expect(tkCloseSquare)
      EmitPush()
      EmitLoad(SymClass, Ofs)
      EmitOperation(opAdd)
    else
      Expect(tkCloseSquare)
      EmitIndexLoadArray(SymClass, Ofs)
    end
    return
  end

  if SymClass = scGlobalConstant begin // constant
    EmitNumber(Ofs)
  else // variable
    EmitLoad(SymClass, Ofs)
  end
end

// recursevly create type data structure
procedure ParseType() : number
begin
  BaseType : number
  if Accept(tkOpenSquare) <> 0 begin
    Expect(tkCloseSquare)
    BaseType := ParseType()
    return TypeAppend(tfVarArray, 0, BaseType, 8)
  end
  if Accept(tkArrow) <> 0 begin
    BaseType := ParseType()
    return TypeAppend(tfPointer, 0, BaseType, 8)
  end
  if Token <> tkIdentifier begin
    Error(erTypeExpected)
  end
  Sym : number := SymLookup()
  if Sym = 0 begin
    Error(erTypeExpected)
  end
  if Buf[Sym + 12] <> scType begin
    Error(erTypeExpected)
  end
  GetToken()
  return GetBuf32(Sym + 8)
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
        return
      end
      ParseStatement()
      Discard : number := Accept(tkSemicolon)
    end
    GetToken() // tkEnd
    EmitScopeEnd(Scope)
    EmitThenEnd(IfBranchPos)
    return
  end

  if Accept(tkWhile) <> 0 begin
    LoopEntry : number := EmitPreWhile()
    ExitBranchPos : number := ParseCondition()
    Expect(tkBegin)
    ParseScope()
    EmitLoop(LoopEntry, ExitBranchPos)
    return
  end

  if Accept(tkReturn) <> 0 begin
    // special case: empty `return` before `end` needs no `;`
    if Token <> tkEnd begin
      if Accept(tkSemicolon) = 0 begin
        ParseExpression()
        Discard2 : number := Accept(tkSemicolon)
      end
    end
    EmitReturn()
    return
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
    return
  end

  if Token <> tkIdentifier begin
    Error(erStatementExpected)
  end
  Sym : number := SymLookup()

  // declaration of variable
  if Sym = 0 begin
    // unknown identifier => must be declaration of variable
    Sym := SymAppend(0 /* don't care */, scLocalVariable)
      // Add a local variable to the symbol table. Must be done before further
      // parsing, otherwise the name of the identifier in TokenBuf is lost.
      // But at this point the address is unknown and will be filled later with
      // SetBuf32()
    Expect(tkColon)
    Buf[Sym + 8] := ParseType()
    if Accept(tkAssign) <> 0 begin
      ParseExpression()
      SymSetClassAddr(Sym, scLocalVariable, EmitLocalVar(1))
    else
      SymSetClassAddr(Sym, scLocalVariable, EmitLocalVar(0))
    end
    return
  end

  SymClass : number := Buf[Sym + 12]
  Ofs      : number := GetBuf32(Sym+4)
  GetToken()

  // procedure call
  if Accept(tkOpenRound) <> 0 begin
    ParseCall(Sym, SymClass, Ofs)
    return
  end

  // assignment to array
  if Accept(tkOpenSquare) <> 0 begin
    ParseExpression()
    Expect(tkCloseSquare)
    Expect(tkAssign)
    EmitIndexPush(SymClass, Ofs)
    ParseExpression()
    EmitPopStoreArray()
    return
  end

  // assignmnet to variable
  if Accept(tkAssign) <> 0 begin
    ParseExpression()
    EmitStore(SymClass, Ofs)
    return
  end

  // Declaration of variable, but identifier is already used.
  // Therefore cover the old declaration temporarily.
  if Token = tkColon begin
    // Fake the token buffer for sym_append(), because it was cleared when the
    // the following token ':' was parsed.
    TokenBuf := Buf[Sym+14 ..]
    TokenInt := Buf[Sym+13]
    Sym := SymAppend(EmitLocalVar(0), scLocalVariable)
    Buf[Sym + 8] := ParseType()
    return
  end

  Error(erStatementExpected)
end

procedure ParseProcedure()
begin
  Sym : number := SymLookup()
  if Sym = 0 begin
    Sym := SymAppend(0 /* don't care */, scUndefinedProcedure)
  else
    GetToken()
  end

  RestoreSymsHead  : number := SymsHead
  RestoreStackHead : number := StackHead
  i : number := 0
  Expect(tkOpenRound)
  while Accept(tkCloseRound) = 0 begin
    i := i + 1
    if Token <> tkIdentifier begin
      Error(erIdentifierExpected)
    end
    ParamSym : number := SymAppend(i, scLocalVariable) // parameters are local variables
    Expect(tkColon)
    Buf[ParamSym + 8] := ParseType()
    if Accept(tkComma) = 0 begin

      // Cannot use Expect() directly, because Token may not be changed to exit
      // the loop. Therefore call Expect() only, if sure there is an error.
      if Token <> tkCloseRound begin
        Expect(tkCloseRound)
      end
    end
  end

  if Accept(tkColon) <> 0 begin
    ReturnType : number := ParseType() // FIXME: store the ReturnType somewhere
  end

  if Accept(tkForward) = 0 begin
    Expect(tkBegin)
    SymFix(Sym, EmitFuncBegin(i))
    ParseScope()
    EmitFuncEnd()
  end
  SymsHead  := RestoreSymsHead  // remove local variables from symbol table
  StackHead := RestoreStackHead
end

procedure ParseDeclaration()
begin
  GetToken() // ignore keyword `module`
  GetToken() // ignore name of module
  Discard : number := Accept(tkSemicolon)

  while Accept(tkBegin) = 0 begin // while NOT begin
    if Token = tkIdentifier begin
      Sym : number := SymAppend(EmitGlobalVar(), scGlobalVariable)
      if Accept(tkColon) <> 0 begin
        Buf[Sym + 8] := ParseType()
      end
      if Accept(tkEQ) <> 0 begin
        if Token = tkIntegerLiteral begin
          SymSetClassAddr(Sym, scGlobalConstant, TokenInt)
          GetToken()
        else
          if Token = tkStringLiteral begin
            Addr  : number := EmitBinaryFunc(TokenInt, TokenBuf)
            Align : number := TokenInt & 3
            EmitBinaryFunc(4 - Align, ''00000000)
            SymSetClassAddr(Sym, scGlobalConstant, Addr + BaseAddr)
            GetToken()
          else
            Error(erConstantExpected)
          end
        end
      end

    else
      if Accept(tkProcedure) <> 0 begin
        ParseProcedure()
      else
        Error(erDeclarationExpected)
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
  Buf           := BrkAlloc(BufSize + 1024 + 16)
  SymsHead      := BufSize
  StackHead     := BufSize
  LineNo        := 1
  LineCol       := 0
  CodePos       := 0

  LineBuf       := Buf[BufSize ..]
  DigitBuf16    := Buf[BufSize+1024 ..]

  SymInit()
  NextChar()
  GetToken()
  CallMain : number := EmitBegin()
  ParseDeclaration()
  EmitFixCall(CallMain, CodePos)
  ParseMain()
  Emit32(1299)          // 13 05 00 00  li a0, 0
  Emit32(97519763)      // 93 08 D0 05  li a7, 93
  Emit32(115)           // 73 00 00 00  ecall
  PosixWrite(1, Buf, EmitEnd())
end.
