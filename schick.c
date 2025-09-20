/*  The programming language Schick

    Scanner

Token
    operations    conditions    other    reserved words predefined identifiers
                  50h 'P' =     28h (    03h procdure   0Ah number
    41h 'A' <<    51h 'Q' <>    29h )    04h begin      0Bh char
    42h 'B' >>    52h 'R' <     2Ch ,    05h end        0Ch posix
    43h 'C' -     53h 'S' >=    3Ah :    06h if         0Dh write
    44h 'D' |     54h 'T' >     3Bh ;    07h else       0Eh getchar
    45h 'E' ^     55h 'U' <=    5Bh [    08h while
    46h 'F' +                   5Dh ]    09h return     special
    47h 'G' &                                           00h EOF
    48h 'H' *     61h 'a' :=                            01h string
    49h 'I' /     62h 'b' ->                            0Fh identifier
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
    const char  *classify  = "         ##  #                  #    JG!()HF,C.#^^^^^^^^^^:;R=T  __________________________[ ]E_ __________________________ D   ";
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
        while (1) {
            (void)next_char();
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
        const char *keywords = "9procedure5begin3end2if4else5while6return6number4char5posix5write7putchar0";
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
        /* token = 15 0x0F identifier */
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


int main(void)
{
    buf_size  = 65536;
    buf       = malloc(buf_size);
    syms_head = buf_size;
    lineno    = 1;
    code_pos  = 0;
    (void)next_char();

    token = 1;
    while (token != 0) {
        get_token();
        itoa4(token);

        if (token == '^') {
            write(2, " NUM", 4);
        }
        else if (token > 31) {
            buf[0] = ' ';
            buf[1] = token;
            write(2, buf, 2);
        }
        else if (token == 3) {
            write(2, " STR", 4);
            write(2, token_buf, token_int);

        }
        else if (token == 3) { write(2, " procedure", 10); }
        else if (token == 4) { write(2, " begin", 6); }
        else if (token == 5) { write(2, " end", 4); }
        else if (token == 6) { write(2, " if", 3); }
        else if (token == 7) { write(2, " else", 5); }
        else if (token == 8) { write(2, " while", 6); }
        else if (token == 9) { write(2, " return", 7); }
        else if (token == 10) { write(2, " number", 7); }
        else if (token == 11) { write(2, " char", 5); }
        else if (token == 12) { write(2, " posix", 6); }
        else if (token == 13) { write(2, " write", 6); }
        else if (token == 14) { write(2, " getchar", 8); }
        else if (token == 15) {
            write(2, " ID ", 4);
            write(2, token_buf, token_int);
        }

        write(2, "\x0d\x0a", 2);
    }
    return 0;
}
