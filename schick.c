/*  The programming language Schick

Error return codes

    0100 buffer overflow
    0101 invalid character
    0102 specific token expected
        0103 identifier expected
    0104 unknown identifier
        0105 function redefined
    0106 type expected
    0110 `begin` of main routine  expected
    0111 statement expected
    0112 number expected (in constant declaration)
    0199 expression expected

Symbol Type

    70 global constant (32 bit number)
    71 global variable
    72 undefined function
    73 defined function
    74 local variable (or argument)

Token
    operations    conditions    other    reserved words predefined identifiers
                  50h 'P' =     28h (    03h procedure  0Dh number
    41h 'A' <<    51h 'Q' <>    29h )    04h begin      0Eh char
    42h 'B' >>    52h 'R' <     2Ch ,    05h end        0Fh string
    43h 'C' -     53h 'S' >=    3Ah :    06h if         10h byte
    44h 'D' |     54h 'T' >     3Bh ;    07h else       11h boolean
    45h 'E' ^     55h 'U' <=             08h while      12h false
    46h 'F' +                   5Bh [    09h return     13h true
    47h 'G' &                   5Dh ]    0Ah #asm
    48h 'H' *     61h 'a' :=             0Bh #forward
    49h 'I' /     62h 'b' ->             0Ch var
    4Ah 'J' %     63h 'c' ..

    special
    00h EOF
    01h a string
    1Fh an identifier
    5Eh '^' a number
*/

void exit(int);
int getchar(void);
void *malloc(unsigned long);
int putchar(int);
int write(int, char*, int);




/**********************************************************************
 * Code generation for RV32IM from punycc
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
 **********************************************************************/



unsigned int buf_size;          /* total size of the buffer */
unsigned char *buf;             /* pointer to the buffer */
unsigned int code_pos;          /* position in the buffer for code generation */
unsigned int num_locals;        /* number of local variables in the current function */
unsigned int num_globals;       /* number of global variables */

unsigned int reg_pos;
unsigned int last_insn;
unsigned int last_insn_type;
    /*  8 push imm12
       10 push uimm32
       11 push reg (used as local variable)
       13 push mem (used as global or loval variable)
       14 arith operation
       15 comparison
       8...15 write into the destination register
    */
unsigned int return_list;
unsigned int max_locals;
unsigned int function_start_pos;
unsigned int last_branch_target;
    /* Position where the last branch points to.
       Used to determine the length of the last uninterrupted sequences of
       instructions. */
unsigned int num_scope;
unsigned int num_calls;
unsigned int max_reg_pos;

char *local_reg;





/* helper to write a 32 bit number to a char array */
void set_32bit(unsigned char *p, unsigned int x)
{
    p[0] = x;
    p[1] = x >> 8;
    p[2] = x >> 16;
    p[3] = x >> 24;
}

/* helper to read 32 bit number from a char array */
unsigned int get_32bit(unsigned char *p)
{
    return p[0] +
          (p[1] << 8) +
          (p[2] << 16) +
          (p[3] << 24);
}


unsigned int emit_binary_func(unsigned int n, char *s)
{
    unsigned int cp = code_pos;
    unsigned int i = 0;
    while (i < n) {
        buf[cp + i] = s[i];
        i = i + 1;
    }
    code_pos = cp + n;
    return cp;
}

void emit32(unsigned int n)
{
    unsigned int cp = code_pos;
    code_pos = cp + 4;
    last_insn = n;
    last_insn_type = 0;
    set_32bit(buf + cp, n);
}

void emit_isdo(unsigned int imm, unsigned int rs, unsigned int rd, unsigned int opcode)
{
    emit32((imm << 20) + (rs << 15) + (rd << 7) + opcode);
}

unsigned int insn_jal(unsigned int rd, unsigned int immj)
{
    return
        (((immj>>20) & 1) << 31) |      /* bit  31     = imm[20] */
        (((immj & 2046  )        |      /* bits 30..21 = imm[10..1] */
         ((immj>>11) & 1))<< 20) |      /* bit  20     = imm[11] */
        ((immj & 1044480)      ) |      /* bits 19..12 = imm[19..12] */
        ( rd              <<  7) |      /* bits 11..7  = rd */
        111;                            /* bits  6..0  = 0x6f (jal) */
}

void emit_push()
{
    reg_pos = reg_pos + 1;
    if (reg_pos > max_reg_pos) max_reg_pos = reg_pos;
}

void emit_number(unsigned int imm)
{
    if (((imm + 2048) >> 12) == 0) {
        emit_isdo(imm, 0, reg_pos, 19);
                /* 00000013  ADDI REG[reg_pos], X0, imm */
        last_insn_type = 8;
    }
    else {
        emit32((((imm + 2048) >> 12) << 12) + (reg_pos << 7) + 55);
                /* 00000037  LUI REG[reg_pos], imm */
        if ((imm << 20) != 0) {
            emit_isdo(imm, reg_pos, reg_pos, 19);
                /* 00000013  ADDI REG[reg_pos], REG[reg_pos], imm */
        }
        last_insn_type = 10;
    }
}

void emit_string(unsigned int len, char *s)
{
    unsigned int aligned_len = (len + 4) & 4294967292;
        /* there are 4 zero bytes appended to s */
    emit32(insn_jal(reg_pos, aligned_len + 4));
        /* JAL REG[reg_pos], align(end_of_string) */
    emit_binary_func(aligned_len, s);
}

void emit_store(unsigned int global, unsigned int ofs)
{
    /* When called from punycc.c, reg_pos is always 10.
       But it is called from emit_pre_call() (via emit_local_var())
       to save the parameter stack. In the latter case, reg_pos
       can be higher. */

    if (global == 0) {
        if (ofs < 13) {
            if (last_insn_type > 7) {
                code_pos = code_pos - 4;
                emit32((last_insn & 4294963327) | (local_reg[ofs] << 7));
                    /*              0xFFFFF07F */
            }
            else {
                emit_isdo(0, reg_pos, local_reg[ofs], 19);
                    /* ADDI REG[local_reg[ofs]], REG[reg_pos], 0 */
            }
            return;
        }
        /* more than 13 local vars: fall back to stack */
    }
    emit32(73763 +
        (global << 15) +
        (reg_pos << 20) +
        ((ofs & 1016   ) << 22) +       /* bits 31..25 = ofs[9..3] */
        ((ofs & 7      ) <<  9));       /* bits 11..7  = ofs[2..0] 0 0  */
        /* SW REG[reg_pos], (ofs+1)(REG[2+global]) */
}

void emit_load(unsigned int global, unsigned int ofs)
{
    if (global == 0) {
        if (ofs < 13) {
            emit_isdo(0, local_reg[ofs], reg_pos, 19);
                /* ADDI REG[reg_pos], REG[local_reg[ofs]], 0 */
            last_insn_type = 11; /* push reg */
            return;
        }
        /* more than 13 local vars: fall back to stack */
    }
    emit_isdo(ofs << 2, global, reg_pos, 73731);
        /* LW reg_pos, ofs(REG[2+global]) */
    last_insn_type = 13; /* push mem */
}

/* Same as emit_isdo(), but rs=reg_pos and if REG[reg_pos] is loaded from
   a local variable in the previous instruction, fuse them. */
void emit_irdo(unsigned int imm, unsigned int rd, unsigned int opcode)
{
    unsigned int rs = reg_pos;
    unsigned int prev_insn = get_32bit(buf + code_pos - 4);
    if ((prev_insn & 4293947519) == 19) {
        /*           0xfff0707f) == 0x13)    ADDI REG[reg_pos], REG[local], 0 */
        if (((prev_insn >> 7) & 31) == reg_pos) { /* really necessary? */
            /* load local*/
            rs = (prev_insn >> 15) & 31;
            code_pos = code_pos - 4;
        }
    }
    emit_isdo(imm, rs, rd, opcode);
    last_insn_type = 14; /* arith operation */
}

void emit_operation(unsigned int operation)
{
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

    unsigned int imm = reg_pos;
    reg_pos = imm - 1;

    unsigned int shift = operation + operation + operation - 3;
    unsigned int op = (((1025264681 >> shift) & 7) << 12) + 51;
        /* octal: 75'0704'6051 */
    if (operation > 7) op = op + 33554432; /* 0x0200'0000 */
    if (operation == 3) op = 1073741875;  /* 0x4000'0033 */

    /* code optimisation if second operand is a load from register */
    if (last_insn_type == 11) { /* push reg */
        imm = (last_insn >> 15) & 31;
        code_pos = code_pos - 4;
    }

    /* code optimisation for constant immediates */
    if (operation < 8) {
        if ((last_insn & 1044607) == 19) {
            /* 0xFF07F  ADDI ?, X0, ?
               register need not be checked
               if (((last_insn & 1048575) == (19 + ((reg_pos + 11) << 7))) { */
            imm = last_insn >> 20;
            if (operation == 3) imm = 0 - imm;
                /* 00000013  ADDI reg, reg, -imm
                   imm is always positive, therefore -(-2048)=2048
                   cannot happen */
            code_pos = code_pos - 4;
            op = (((1854505 >> shift) & 7) << 12) + 19;
                /* octal: 704'6051 */
        }
    }
    emit_irdo(imm, reg_pos, op);
}

void emit_comp(unsigned int condition)
{
    reg_pos = reg_pos - 1;

    if (condition < 2) {
        if ((last_insn & 4294963327) == 19) {
            /* 0xFFFFF07F optimization if compared with 0 */
            code_pos = code_pos - 4;
        }
        else {
            emit_isdo(reg_pos, reg_pos, reg_pos, 1074790451);
                /* sub REG, REG, REG+1 */
        }
        if (condition == 0) {
            emit_isdo(0, reg_pos, reg_pos, 1060883);
                /* sltiu REG, REG, 1        == */
        }
        else {
            emit_isdo(reg_pos, 0, reg_pos, 12339);
                /* sltu REG, x0, REG        != */
        }
    }
    else {
        unsigned int o = 45107;
            /* 0000B033  sltu REG, REG+1, REG     > or <= */
        if (condition < 4) o = 1060915;
            /* 00103033  sltu REG, REG, REG+1     < or >= */
        emit_isdo(reg_pos, reg_pos, reg_pos, o);
        if ((condition & 1) != 0) {
            emit_isdo(0, reg_pos, reg_pos, 1064979);
                /* xori REG, REG, 1         >= or <= */
        }
    }
    last_insn_type = 13; /* arith comparison */
}

void emit_index_push(unsigned int global, unsigned int ofs)
{
    emit_push();
    emit_load(global, ofs);
    emit_operation(6); /* add */
    emit_push();
    last_insn_type = 14; /* arith operation */
}

void emit_pop_store_array()
{
    /* reg_pos is always 11 at this point */
    reg_pos = 10;
    emit32(11862051);
        /* 00B50023  SB A1,0(A0) */
}

void emit_index_load_array(unsigned int global, unsigned int ofs)
{
    unsigned int imm = 0;
    unsigned int rs = reg_pos;
    if (last_insn_type == 8) { /* push imm12 */
        imm = last_insn >> 20;
        code_pos = code_pos - 4;
        rs = local_reg[ofs];
        if ((global != 0) | (ofs >= 13)) {
            emit_load(global, ofs);
            rs = reg_pos;
        }
    }
    else {
        emit_index_push(global, ofs);
        reg_pos = reg_pos - 1;
    }
    emit_isdo(imm, rs, reg_pos, 16387);
        /* LBU REG[reg_pos], 0(REG[reg_pos]) */
}

unsigned int emit_pre_while()
{
    return code_pos;
}

unsigned int emit_if(unsigned int condition)
{
    /* at function entry reg_pos is always 11 */
    unsigned int rs = 10;
    unsigned int rt = 11;

    /* code optimisation if first operand is a local register */
    unsigned int prev_insn = get_32bit(buf + code_pos - 8);
    if ((prev_insn & 4293951487) == 1299) {
        /*           0xfff07fff) == 0x513     ADDI A0, x?, 0 */
        rs = (prev_insn >> 15) & 31;
        code_pos = code_pos - 8;
        emit32(last_insn);
    }

    /* code optimisation if second operand is a local register */
    if (last_insn_type == 11) { /* push reg */
        rt = (last_insn >> 15) & 31;
        code_pos = code_pos - 4;
    }

    /* code optimisation if second operand is 0 */
    if (last_insn == 1427) { /* 00000593  ADDI A1, X0, 0 */
        rt = 0;
        code_pos = code_pos - 4;
    }

    /* 0  00001063     BNE  s, t, +0    ==
       1  00000063     BEQ  s, t, +0    !=
       2  00007063     BGEU s, t, +0   <
       3  00006063     BLTU s, t, +0   >=
       4  00007063     BGEU t, s, +0   >
       5  00006063     BLTU t, s, +0   <= */
    if (condition > 3) {
        unsigned h = rs;
        rs = rt;
        rt = h;
        condition = condition - 2;
    }
    emit_isdo(rt, rs, 0,
        ((condition & 2) << 13) |
        (((condition & 3) ^ 1) << 12) | 99);
/*
    emit32(
        (rt << 20) |
        (rs << 15) |
        ((condition & 2) << 13) |
        (((condition & 3) ^ 1) << 12) |
        99);
*/
    reg_pos = 10;
    return code_pos - 4;
}

void emit_then_end(unsigned int insn_pos)
{
    unsigned int immb = code_pos - insn_pos;
    immb = 
        ((immb & 4096) << 19) |     /* bit  31     = immb[12] */
        ((immb & 2016) << 20) |     /* bits 30..25 = immb[10..5] */
        ((immb &   30) <<  7) |     /* bits 11..8  = immb[4..1] */
        ((immb & 2048) >>  4);      /* bit  7      = immb[11] */
    set_32bit(buf + insn_pos, (get_32bit(buf + insn_pos) & 33550463) | immb);
    last_branch_target = code_pos;
}

void emit_else_end(unsigned int insn_pos)
{
    set_32bit(buf + insn_pos, insn_jal(0, code_pos - insn_pos));
    last_branch_target = code_pos;
}

static unsigned int emit_then_else(unsigned int insn_pos)
{
    emit32(0);
    emit_then_end(insn_pos);
    return code_pos - 4;
}

static void emit_loop(unsigned int destination, unsigned int insn_pos)
{
    emit32(insn_jal(0, destination - code_pos));
    emit_then_end(insn_pos);
}

unsigned int emit_local_var(unsigned int init)
{
    unsigned int n = num_locals + 1;
    num_locals = n;
    if (n > max_locals) max_locals = n;

    if (init != 0) {                                 /* set initial value */
        emit_store(0, n);
    }

    return n;
}

unsigned int emit_global_var()
{
    num_globals = num_globals + 1;
    return num_globals - 513;
}

unsigned int emit_pre_call()
{
    /* save expression stack it it is not empty */
    unsigned int r = reg_pos;
    if (r > 10) {
        /* save currently used expression stack registers */
        while (reg_pos > 10) {
            reg_pos = reg_pos - 1;
            emit_local_var(1);
        }
    }
    reg_pos = 10;
    return r;
}

void emit_arg()
{
    emit_push();
}

unsigned int emit_call(unsigned int ofs, unsigned int pop, unsigned int save)
{
    unsigned int r = code_pos;
    emit32(insn_jal(1, ofs - code_pos));
    num_calls = num_calls + 1;

    if (save > 10) {
        /* restore previously saved expression stack registers */
        emit32((save << 7) + 327699);
            /* 000500513  MV REG[reg_pos], A0 */

        reg_pos = 10;
        while (reg_pos < save) {
            emit_load(0, num_locals);
            reg_pos = reg_pos + 1;
            num_locals = num_locals - 1;
        }
    }
    last_insn_type = 0; /* avoid fusion with next instruction */

    reg_pos = save;
    return r;
}

void emit_fix_call(unsigned int from, unsigned int to)
{
    set_32bit(buf + from, insn_jal(1, to - from));
}

unsigned int emit_func_begin(unsigned int n)
{
    unsigned int cp0 = code_pos;
    unsigned int cp8 = cp0 + 8;
    function_start_pos = cp0;
    reg_pos = 10;
    max_reg_pos = 10;
    num_locals = n;
    max_locals = n;
    num_scope = 0;
    num_calls = 0;
    return_list = 0;

    last_branch_target = cp8;
    code_pos = cp8;
        /* The first two instructions will be written by emit_func_end,
           when the number of local variables is known. */

    return cp0;
}

void emit_return()
{
    emit32(return_list);
        /* will be overwritten by a jump to the end of the function */
    return_list = code_pos - 4;
}

void emit_func_end()
{
    unsigned int m = max_locals;

    /* Set stack reservation at start of function.
       Stack pointer must be a multiple of 16.
       Shift by 20 is an optimisation to save the imm field shift */
    unsigned int stack_size = ((m + 4) >> 2) << 24;
    set_32bit(buf + function_start_pos, 65811 - stack_size);
        /* 00010113  ADD SP, SP, 0-stack_size */

    /* entry to prologue depends on number of local variables */
    unsigned int entry = 100 - function_start_pos;
    if (m < 9) {
        entry = entry + 80 - (m << 3);
    } else if (m < 12) {
        entry = entry + 48 - (m << 2);
    }
    entry = insn_jal(5, entry);
        /* J _prologue */
    set_32bit(buf + function_start_pos + 4, entry);

    /* go throught list of return statements */
    unsigned int cp = code_pos;
    unsigned int next = return_list;
    if (next == (cp - 4)) {
        /* remove last jump to following instruction */
        cp = cp - 4;
        code_pos = cp;
    }
    while (next != 0) {
        unsigned int pos = next;
        next = get_32bit(buf + pos);
        set_32bit(buf + pos, insn_jal(0, cp - pos));
    }

    /* emit jump to epilogue */
    emit32(stack_size + 659);
        /* 00000593  ADDI X5, X0, stack_size */
    emit32(insn_jal(0, 236 - (m << 2) - cp));
        /* J _epilogue + 4*(12-num_locals) */
}

unsigned int emit_scope_begin()
{
    num_scope = num_scope + 1;
    return num_locals;
}

void emit_scope_end(unsigned int save)
{
    num_locals = save;
    num_scope = num_scope - 1;
}

unsigned int emit_begin()
{
    code_pos = 0;
    num_globals = 0;
    last_branch_target = 0;
    local_reg = " \x08\x09\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b";
    emit_binary_func(252, "\x7f\x45\x4c\x46\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00\x01\x00\x00\x00\x54\x00\x01\x00\x34\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x34\x00\x20\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00........\x07\x00\x00\x00\x00\x10\x00\x00\x13\x00\x00\x00\x13\x00\x00\x00\x00\x00\x00\x00\x93\x68\xd0\x05\x73\x00\x00\x00\x23\x28\xb1\x03\x23\x26\xa1\x03\x23\x24\x91\x03\x23\x22\x81\x03\x23\x20\x71\x03\x93\x8b\x08\x00\x23\x2e\x61\x01\x13\x0b\x08\x00\x23\x2c\x51\x01\x93\x8a\x07\x00\x23\x2a\x41\x01\x13\x0a\x07\x00\x23\x28\x31\x01\x93\x89\x06\x00\x23\x26\x21\x01\x13\x09\x06\x00\x23\x24\x91\x00\x93\x84\x05\x00\x23\x22\x81\x00\x13\x04\x05\x00\x23\x20\x11\x00\x67\x80\x02\x00\x83\x2d\x01\x03\x03\x2d\xc1\x02\x83\x2c\x81\x02\x03\x2c\x41\x02\x83\x2b\x01\x02\x03\x2b\xc1\x01\x83\x2a\x81\x01\x03\x2a\x41\x01\x83\x29\x01\x01\x03\x29\xc1\x00\x83\x24\x81\x00\x03\x24\x41\x00\x83\x20\x01\x00\x33\x01\x51\x00\x67\x80\x00\x00");
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
    005C 00 00 00 00    jal x1, main
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

    return 92;
        /* return the address of the call to main() as a forward reference */
}

unsigned int emit_end()
{
    unsigned int addr = code_pos + 1964; /* 2048 - 84 */
    set_32bit(buf + 84, (((addr + 2048) >> 12) << 12) + 407);
        /* 00000197  AUIPC GP, hi(addr) */
    set_32bit(buf + 88, (addr << 20) + 98707);
        /* 00018193  ADDI GP, GP, lo(addr) */
    unsigned int i = 0;
    while (i < num_globals) {
        emit32(0);
        i = i + 1;
    }

    set_32bit(buf + 68, code_pos);
    set_32bit(buf + 72, code_pos);
    return code_pos;
}




/**********************************************************************
 * Scanner
 **********************************************************************/

static unsigned int ch;
static unsigned int ch_class;
static unsigned int lineno;
static unsigned int token;
static unsigned int token_int;
static unsigned int token_size;
static char *token_buf;
static unsigned int syms_head;

static void itoa4(unsigned int x)
{
    unsigned int i = x * 134218; /* x = x * (((1<<27)/1000) + 1) */
    char *s = (char *)buf + syms_head - 16;
    s[0] = (i>>27) + '0';
    i = (i & 134217727) * 5;  /* 0x07FFFFFF */
    s[1] = (i>>26) + '0';
    i = (i & 67108863) * 5;   /* 0x03FFFFFF */
    s[2] = (i>>25) + '0';
    i = (i & 33554431) * 5;   /* 0x01FFFFFF */
    s[3] = (i>>24) + '0';
    write(2, s, 4);
}

static void error(unsigned int no)
{
    write(2, "Error ", 6);
    itoa4(no);
    write(2, " in line ", 9);
    itoa4(lineno);
    write(2, ".\x0d\x0a", 3);
    exit(no);
}

static unsigned int token_cmp(const char *s, unsigned int n)
{
    unsigned int i = 0;
    while (s[i] == token_buf[i]) {
        i = i + 1;
        if (i == n) {
            return 1;
        }
    }
    return 0;
}

static unsigned int next_char(void)
{
    const char  *classify  = "         ##  #                  #  _ JG!()HF,C.#^^^^^^^^^^:;RPT  __________________________[ ]E_ __________________________ D   ";
        /*                    012345678901234567890123456789012345678901234567890123456789
                                        1         2         3         4         5
         ! = look at character for further processing
         # = whitespace (9, 10, 13, ' ', '/')
         ^ = digit [0123456789]
         _ = letter or underscore
        */
    ch = getchar();
    if (ch == 10) {
        lineno = lineno + 1;
    }
    ch_class = 32; /* ' ' */
    if (ch < 128) {
        ch_class = classify[ch];
    }
    return ch;
}

static void store_char(void)
{
    token_buf[token_int] = ch;
    token_int = token_int + 1;
    if (token_int >= token_size) {
        error(100); /* Error: buffer overflow */
    }
    (void)next_char();
}

static void get_token(void)
{
    unsigned int i;
    unsigned int len;

    token_size = syms_head - code_pos;
    if (token_size < 1024) {
        error(100); /* Error: buffer overflow */
    }
    token_size = token_size - 512;
    token_buf = (char *)buf + code_pos + 256;
    token_int = 0;
    token = 0;

    while (ch_class == '#') { /* ch = 9,10,13,' ','/' */
        if (ch == '/') {
            if (next_char() == '/') {
                while (ch != 10) {
                    (void)next_char();
                }
            }
            else {
                if (ch != '*') {
                    token = 73; /* 'I' /  */
                    return;
                }
                while (next_char() != '/') {
                    while (ch != '*') {
                        (void)next_char();
                    }
                }
            }
        }
        (void)next_char();
    }

    if (ch > 255) { /* End Of File */
        return;
    }
    if (ch_class == ' ') {
        error(101); /* Error: invalid character */
    }

    token = ch_class;
    if (ch == 39) { /* string */
        (void)next_char();
        while (ch != 39) {
            store_char();
        }

        /* hexadecimal appended? */
        (void)next_char();
        i = 0;
        while (i < 16) {
            if (ch_class == '^') { /* '0' ... '9' } */
                i = ch - 48;
            } else {
                if (ch_class == '_') { /* 'A' ... 'F' */
                    i = ch - 55;
                } else {
                    i = 16;
                }
            }
            if (i < 16) {
                len = next_char() - 48; /* '0' */
                if (len > 9) { len = len - 7; }
                ch = (i << 4) + len;
                store_char();
            }
        }
        token = 1; /* 0x01 string */
    }
    else if (ch_class == '^') { /* digit 0...9 */
        while (ch_class == '^') {
            token_int = (10 * token_int) + ch - 48; /* '0' */
            (void)next_char();
        }
        /* token = '^' 0x5E number */
    }
    else if (ch_class == '_') { /* letter or underscore */
        /* store identifier in space between code and symbol table */
        while ((ch_class & 254) == 94) { /* ==94 if  '^' or '_' */
            store_char();
        }
        token_buf[token_int] = 0;

        /* search keyword */
        const char *keywords = "9procedure5begin3end2if4else5while6return4#asm8#forward3var6number4char6string4byte7boolean5false4true0";
        i = 0;
        len = 9;
        token = 3;
        while (len != 0) {
            if (len == token_int) {
                if (token_cmp(keywords + i + 1, token_int) != 0) {
                    return;
                }
            }
            token = token + 1;
            i = i + len + 1;
            len = keywords[i] - '0';
        }
        token = 31; /* 0x1F identifier */
    }
    else if (ch == '<') {
        if (next_char() == '<') {
            (void)next_char();
            token = 65; /* 'A' 0x41 << */
        }
        else {
            if (ch == '=') {
                (void)next_char();
                token = 85; /* 'U' 0x55 <= */
            }
            else {
                if (ch == '>') {
                    (void)next_char();
                    token = 81; /* 'Q' 0x51 <> */
                }
            }
        }
        /* token = 'R' 0x52 < */
    }
    else if (ch == '>') {
        if (next_char() == '=') {
            (void)next_char();
            token = 83; /* 'S' 0x53 >= */
        }
        else {
            if (ch == '>') {
                (void)next_char();
                token = 66; /* 'B' 0x42 >> */
            }
        }
        /* token = 'T' 0x54 > */
    }
    else if (ch == ':') {
        if (next_char() == '=') {
            (void)next_char();
            token = 'a'; /* assignment */
        }
        /* token = ':' 0x3A */
    }
    else if (ch == '-') {
        if (next_char() == '>') {
            (void)next_char();
            token = 'b'; /* pointer */
        }
        /* token = 'C' - */
    }
    else if (ch == '.') {
        if (next_char() == '.') {
            (void)next_char();
            token = 'c'; /* .. */
        }
        /* token = '.' 0x2E */
    }
    else {
        /* case for ()+,;=[] */
        (void)next_char();
    }
}





/**********************************************************************
 * Symbol Management
 **********************************************************************/


static unsigned int sym_lookup(void)
{
    if (token != 31) {
        error(103); /* Error: identifier expected */
    }
    unsigned int s = syms_head;
    while (s < buf_size) {
        unsigned int len = buf[s + 5];
        if (len == token_int) {
            if (token_cmp((char *)buf + s + 6, token_int) != 0) {
                return s;
            }
        }
        s = s + len + 6;
    }
    return 0;
}

static void sym_append(unsigned int addr, unsigned int type)
{
    unsigned int i = token_int;
    syms_head = syms_head - token_int - 6;
    unsigned char *s = buf + syms_head;

    set_32bit(s, addr);
    s[4] = type;
    s[5] = i;

    /* copy backwards in case the token and the symbol table overlap */
    while (i != 0) {
        i = i - 1;
        s[6 + i] = token_buf[i];
    }
    get_token();
}


static void sym_fix(unsigned int sym, unsigned int func_pos)
{
    unsigned char *s = buf + sym;
    unsigned int i = get_32bit(buf + sym);
    unsigned int next;

    if (s[4] != 72) {
        error(105); /* Error: function redefined */
    }

    while (i != 0) {
        next = get_32bit(buf + i);
        emit_fix_call(i, func_pos);
        i = next;
    }
    set_32bit(s, func_pos);
    s[4] = 73;
}





/**********************************************************************
 * Parser
 **********************************************************************/

static unsigned int accept(unsigned int ch)
/* parameter named `ch` to check if name scopes work */
{
    if (token == ch) {
        get_token();
        return 1;
    }
    return 0;
}

static void expect(unsigned int t)
{
    if (accept(t) == 0) {
        error(200+t);
        error(102); /* Error: specific token expected */
    }
}

static unsigned int accept_type(void)
{
    /* accept any combination of [ ] -> followed by a type identifier */
    while (1) {
        if (token == 'b'/* -> */) {
            get_token();
        }
        if (token == 91/* [ */) {
            get_token();
        }
        else if (token == 93/* ] */) {
            get_token();
        }
        else if ((token - 13) <= 4) {
            /* 13 number
               14 char
               15 string
               16 byte
               17 boolean */
            get_token();
            return 1;
        }
        else {
            return 0;
        }
    }
}

static void expect_type(void)
{
    if (accept_type() == 0) {
        error(106); /* Error: type expected */
    }
}

static void parse_factor(void);

static void parse_expression(void)
{
    parse_factor();
    while ((token & 240) == 64) {
        emit_push();
        unsigned int op = token & 15;
        get_token();
        parse_factor();
        emit_operation(op);
    }
}

static unsigned int parse_condition(void)
{
    parse_expression();
    emit_push();
    unsigned int cond = token & 15;
    get_token();
    parse_expression();
    return emit_if(cond);
}

static void parse_call(unsigned int sym, unsigned int type, unsigned int ofs)
{
    unsigned int argno = 0;
    unsigned int save = emit_pre_call();
    if (accept(')') == 0) {
        parse_expression();
        emit_arg();
        argno = argno + 1;
        while (accept(',') != 0) {
            parse_expression();
            emit_arg();
            argno = argno + 1;
        }
        expect(')');
    }

    unsigned int link = emit_call(ofs, argno, save);
    if (type == 72) {
        set_32bit(buf + link, ofs); 
            /* overwrite the call to an undefined address with a link
               to the rest of the linked list of calls to this not yet
               defined function */
        set_32bit(buf + sym, link);
    }
}

static void parse_factor(void)
{
    unsigned int sym;
    unsigned int type;
    unsigned int ofs;

    while (token == '(') { /* '(' */
        get_token();
        parse_expression();
        expect(')');
        return;
    }

    if (token == '^') { /* number */
        emit_number(token_int);
        get_token();
    }
    else if (token == 1) { /* string */
        set_32bit((unsigned char *)token_buf + token_int, 0);
            /* append 4 zero bytes to simplify alignment in the backends */
        emit_string(token_int, token_buf);
        get_token();
    }
    else if (token == 18/*false*/) {
        emit_number(0);
        get_token();
    }
    else if (token == 19/*true*/) {
        emit_number(1);
        get_token();
    }
    else { /* identifier */
        sym = sym_lookup();
        get_token();
        if (sym == 0) {
            error(104); /* Error: unknown identifier */
        }

        type = buf[sym + 4];
        ofs = get_32bit(buf + sym);

        if (accept('(')) {
            parse_call(sym, type, ofs);
        }
        else if (accept('[') != 0) { /* array */
            parse_expression();
            if (accept('c'/*...*/)) {
                expect(']');
                emit_push();
                emit_load(type & 1, ofs);
                emit_operation(6); /* add */
            }
            else {
                expect(']');
                emit_index_load_array(type & 1, ofs);
            }
        }
        else if (type == 70) { /* global constant */
            emit_number(ofs);
        }
        else { /* variable */
            emit_load(type & 1, ofs);
        }
    }
}

static void parse_statement(void)
{
    unsigned int h;
    unsigned int s;

    if (accept(';')) {
        /* nothing to do */
    } else if (accept(6/*if*/) != 0) {
        h = parse_condition();
        expect(4/*begin*/);
        while (token != 5/*end*/) {
            if (token == 7/*else*/) {
                s = emit_then_else(h);
                get_token();
                while (token != 5/*end*/) {
                    parse_statement();
                }
                emit_else_end(s);
                get_token();
                return;
            }
            parse_statement();
        }
        emit_then_end(h);
        get_token();
    }
    else if (accept(8/*while*/) != 0) {
        h = emit_pre_while();
        s = parse_condition();
        expect(4/*begin*/);
        while (token != 5/*end*/) {
            parse_statement();
        }
        emit_loop(h, s);
        get_token();
    }
    else if (accept(9/*return*/) != 0) {
        if (accept(';') == 0) {
            parse_expression();
            accept(';');
        }
        emit_return();
    }
    else if (accept(10/*#asm*/)) {
        while (token != 5/*end*/) {
            expect('.');
            expect(15/*"string"*/);
            emit_binary_func(token_int, token_buf);
            expect(1/*a string constant*/);
        }
        get_token(); /* end */
    }
    else { /* identifier */
        unsigned int sym = sym_lookup();
        if (sym == 0) {
            /* unknown identifier => must be declaration of variable */
            sym_append(0 /* don't care */, 74);
                /* Add a local variable to the symbol table. Must be done before
                   further parsing, otherwise the name of the identifier in
                   token_buf is lost. But at this point the address is unknown
                   and will be filled later with set_32bit() */
            expect(':');
            expect_type();
            s = 0;
            if (accept('a'/* := */) != 0) {
                parse_expression();
                s = 1;
            }
            set_32bit(buf + syms_head, emit_local_var(s));
            accept(';');
        }
        else {
            unsigned int type = buf[sym + 4];
            unsigned int ofs = get_32bit(buf + sym);
            get_token();

            if (accept('(')) {
                parse_call(sym, type, ofs);
            }
            else if (accept('[') != 0) { /* array */
                parse_expression();
                expect(']');
                expect('a'/*:=*/);
                emit_index_push(type & 1, ofs);
                parse_expression();
                emit_pop_store_array();
            }
            else if (accept('a'/*:=*/) != 0) { /* assignment to variable */
                parse_expression();
                emit_store(type & 1, ofs);
            }
            else if (accept(':') != 0) {
                /* Declaration of variable, but identifier is already used.
                   Therefore cover the old declaration temporarily.
                   Fake the token buffer for sym_append() */
                token_buf = (char *)buf + sym + 6;
                token_int = buf[sym + 5];
                sym_append(emit_local_var(0), 74); /* local variable */
                expect(':');
                expect_type();
                accept(';');
            }
            else {
                error(111); /* Error: statement expected */
            }
        }
    }
}

static void parse_procedure(void)
{
    unsigned int sym = sym_lookup();
    if (sym != 0) {
        get_token();
    }
    else {
        sym_append(0, 72); /* undefined function */
        /* get_token(); implicit in sym_append() */
        sym = syms_head;
    }

    unsigned int restore_head = syms_head;
    unsigned int n = 0;
    expect('(');
    while (accept(')') == 0) {
        n = n + 1;
        if (token == 31/*an identifier*/) {
            sym_append(n, 74); /* local argument */
            expect(':');
        }
        expect_type();
        (void)accept(','); /* ignore trailing comma */
    }

    /* optional return type */
    if (accept(':')) {
        expect_type();
    }

    if (accept(15/*#forward*/) == 0) {
        expect(4/*begin*/);
        sym_fix(sym, emit_func_begin(n));
        while (token != 5/*end*/) {
            parse_statement();
        }
        get_token(); /* end */
        emit_func_end();
    }
    syms_head = restore_head; /* remove local variables from symbol table */
}

static void parse_declaration(void)
{
    get_token(); /* ignore keyword `module` */
    get_token(); /* ignore name of module */
    accept(';');

    while (accept(4/*begin*/) == 0) { /* while NOT begin */
        if (token == 31/*an identifier*/) {
            sym_append(emit_global_var(), 71/*global variable*/);
            if (accept(':')) {
                expect_type();
            }
            if (accept('P'/* = */)) {
                if (token != 94/*a number*/) {
                    error(112); /* Error: number expected for constant */
                }
                buf[syms_head + 4] = 70/*global constant*/;
                set_32bit(buf + syms_head, token_int);
                get_token();
            }
            accept(';');
        }
        else if (accept(3/*procedure*/)) {
            parse_procedure();
        }
        else error(110);
        accept(';');
    }
}

static void parse_main(void)
{
    while (token != 5/*end*/) {
        parse_statement();
    }
    expect(5/*end*/);
    expect('.');
}

int main(void)
{
    buf_size  = 65536;
    buf       = malloc(buf_size);
    syms_head = buf_size;
    lineno    = 1;
    code_pos  = 0;

    (void)next_char();
    get_token();
    unsigned int call_main = emit_begin();

    parse_declaration();
    emit_fix_call(call_main, code_pos);
    parse_main();
    emit32(97544339);   /* 93 68 D0 05  or x17, x0, 93 */
    emit32(115);        /* 73 00 00 00  ecall */
    write(1, (char *)buf, emit_end());

    return 0;
}
