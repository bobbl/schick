/*  The programming language Schick

Error return codes

    0100 buffer overflow
    0101 invalid character
    0102 specific token expected
        0103 identifier expected
    0104 unknown identifier
        0105 function redefined
    0106 type expected
    0110 `begin` expected
    0111 statement expected
    0199 expression expected


Token
    operations    conditions    other    reserved words predefined identifiers
                  50h 'P' =     28h (    03h procedure  0Dh number
    41h 'A' <<    51h 'Q' <>    29h )    04h begin      0Eh char
    42h 'B' >>    52h 'R' <     2Ch ,    05h end        0Fh string
    43h 'C' -     53h 'S' >=    3Ah :    06h if
    44h 'D' |     54h 'T' >     3Bh ;    07h else
    45h 'E' ^     55h 'U' <=             08h while
    46h 'F' +                   5Bh [    09h return     special
    47h 'G' &                   5Dh ]    0Ah #asm       00h EOF
    48h 'H' *     61h 'a' :=             0Bh #forward   01h string
    49h 'I' /     62h 'b' ->             0Ch var        1Fh identifier
    4Ah 'J' %                                           5Eh '^' number



*/

#include <stdio.h>


/* constants */
unsigned int buf_size;

/* global variables */
unsigned char *buf;
unsigned int code_pos;

void exit(int);
int getchar(void);
void *malloc(unsigned long);
int putchar(int);
int write(int, char*, int);




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

void emit_push()
{
    write(2, "PUSH\x0d\x0a", 6);
}

void emit_number(unsigned int imm)
{
    write(2, "number\x0d\x0a", 8);
}

void emit_string(unsigned int len, char *s)
{
    write(2, "string\x0d\x0a", 8);
}

void emit_store(unsigned int global, unsigned int ofs)
{
    write(2, "STORE\x0d\x0a", 7);
}

void emit_load(unsigned int global, unsigned int ofs)
{
    write(2, "LOAD\x0d\x0a", 6);
}

void emit_operation(unsigned int operation)
{
    write(2, "OPERATION\x0d\x0a", 11);
}

void emit_comp(unsigned int condition)
{
    write(2, "COMP\x0d\x0a", 6);
}

void emit_index_push(unsigned int global, unsigned int ofs)
{
    write(2, "PUSH INDEX\x0d\x0a", 12);
}

void emit_pop_store_array()
{
    write(2, "POP STORE ARRAY\x0d\x0a", 17);
}

void emit_index_load_array(unsigned int global, unsigned int ofs)
{
    write(2, "LOAD ARRAY\x0d\x0a", 12);
}

unsigned int emit_pre_while()
{
    write(2, "PRE WHILE\x0d\x0a", 11);
}

unsigned int emit_if(unsigned int condition)
{
    write(2, "IF\x0d\x0a", 4);
}

void emit_then_end(unsigned int insn_pos)
{
    write(2, "END (THEN)\x0d\x0a", 12);
}

void emit_else_end(unsigned int insn_pos)
{
    write(2, "END (ELSE)\x0d\x0a", 12);
}

static unsigned int emit_then_else(unsigned int insn_pos)
{
    write(2, "ELSE\x0d\x0a", 6);
}

static void emit_loop(unsigned int destination, unsigned int insn_pos)
{
    write(2, "LOOP\x0d\x0a", 6);
}

unsigned int emit_local_var(unsigned int init)
{
    write(2, "LOCAL VAR\x0d\x0a", 11);
}

unsigned int emit_global_var()
{
    write(2, "GLOBAL VAR\x0d\x0a", 12);
}

unsigned int emit_pre_call()
{
    write(2, "PRE CALL\x0d\x0a", 10);
}

void emit_arg()
{
    write(2, "ARG\x0d\x0a", 5);
}

unsigned int emit_call(unsigned int ofs, unsigned int pop, unsigned int save)
{
    write(2, "CALL\x0d\x0a", 6);
}

void emit_fix_call(unsigned int from, unsigned int to)
{
    write(2, "FIX CALL\x0d\x0a", 10);
}

unsigned int emit_func_begin(unsigned int n)
{
    write(2, "BEGIN (PROCEDURE)\x0d\x0a", 19);
}

void emit_return()
{
    write(2, "RETURN\x0d\x0a", 8);
}

void emit_func_end()
{
    write(2, "END (PROCEDURE)\x0d\x0a", 17);
}

unsigned int emit_begin()
{
    write(2, "BOF\x0d\x0a", 5);
}


unsigned int emit_end()
{
    write(2, "EOF\x0d\x0a", 5);
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
            if (next_char() != '*') {
                token = 73; /* 'I' /  */
                return;
            }
            while (next_char() != '/') {
                while (ch != '*') {
                    (void)next_char();
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
        while (1) {
            if (ch_class == '^') { /* '0' ... '9' } */
                i = ch - 48;
            } else {
                if (ch_class == '_') { /* 'A' ... 'F' */
                    i = ch - 55;
                } else {
                    break;
                }
            }
            len = next_char() - 48; /* '0' */
            if (len > 9) { len = len - 7; }
            ch = (i << 4) + len;
            store_char();
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
        const char *keywords = "9procedure5begin3end2if4else5while6return4#asm8#forward3var6number4char6string0";
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

    else {
        /* case for ()+,.;=[] */
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
    if (accept(13/*number*/)) {
        return 1;
    }
    if (accept(14/*char*/)) {
        return 1;
    }
    if (accept(15/*string*/)) {
        return 1;
    }
    return 0;
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
        emit_string(token_int, token_buf);
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
            expect(']');
            emit_index_load_array(type & 1, ofs);
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
            expect(';');
        }
        emit_return();
    }
    else if (accept(10/*#asm*/)) {
        while (token != 5/*end*/) {
            expect('.');
            expect(15/*"string"*/);
            expect(1/*a string constant*/);
        }
        get_token(); /* end */
    }
    else { /* identifier */
        unsigned int sym = sym_lookup();
        if (sym == 0) {
            /* unknown identifier => must be declaration of variable */
            sym_append(emit_local_var(0), 74); /* local variable */
            expect(':');
            expect_type();
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
    accept(';');
    syms_head = restore_head; /* remove local variables from symbol table */
}

static void parse_module(void)
{
    get_token(); /* ignore keyword `module` */
    get_token(); /* ignore name of module */
    accept(';');

    while (accept(4/*begin*/) == 0) { /* while NOT begin */
        if (accept(2/*var*/)) {
            while (token == 31/*an identifier*/) {
                sym_append(emit_global_var(), 71); /* global variable */
                expect(':');
                expect_type();
                accept(';');
            }
        }
        else if (accept(3/*procedure*/)) {
            parse_procedure();
        }
        else error(110);
    }

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
    token_int = 4;
    token_buf = "main";
    sym_append(emit_begin(), 72); /* implicit get_token() */
    parse_module();
    write(1, (char *)buf, emit_end());

    return 0;
}
