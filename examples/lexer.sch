module Lexer

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

procedure BrkAlloc(Size: number) : string
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



//var
  BufSize       : number        // total size of the buffer
  Buf           : []byte        // the buffer for everything
  CodePos       : number        // position in the buffer for code generation
  NumLocals     : number        // number of local variables in the current fuction
  NumGlobals    : number        // number of global variables

  RegPos        : number
  LastInsn      : number        // itXXX constants
  LastInsnType  : number        // itXXX constants

tkAString       = 1
tkAnIdent       = 31
tkANumber       = 94

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
    PosixWrite(2, DigitBuf16[i .. ], 16 - i)
  end
end

procedure Error(ErrorNo: number)
begin
  PosixWrite(2, 'Error ', 6)
  PrintNumber(ErrorNo);
  PosixWrite(2, ' in line ', 9)
  PrintNumber(LineNo);
  PosixWrite(2, '.'0D0A, 3)
end

procedure TokenCmp(Ident: []byte, Len: number) : boolean
begin
  i : number
  i := 0
  while Ident[i] = TokenBuf[i] begin
    i := i + 1
    if i = Len begin
      return true;
    end
  end
  return false;
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
    Error(100) /* Error: buffer overflow */
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
    Error(100) // Error: buffer overflow
  end
  TokenSize := TokenSize - 512
  TokenBuf  := Buf[CodePos + 256 .. ]
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
    Error(101) // Error: invalid character
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

    Token := tkAString
  else
    if ChClass = 94/* ^ */ begin /* 0...9 */
      while ChClass = 94 begin
        TokenInt := (10 * TokenInt) + Ch - 48
        NextChar()
      end
      Token := tkANumber
    else
      if ChClass = 95/* _ */ begin /* letter or underscore */

        // store identifier in space between code and symbol table
        while (ChClass & 254) = 94 begin /* 94 or 95 */
          StoreChar()
        end
        TokenBuf[TokenInt] := 0

        // search keyword
        Keywords : []byte
        Keywords := '9procedure5begin3end2if4else5while6return4#asm8#forward3var6number4char6string4byte7boolean5false4true0'
        i := 0
        Len := 9
        Token := 3
        while Len <> 0 begin
          if Len = TokenInt begin
            if TokenCmp(Keywords[i+1 ..], TokenInt) <> false begin
              return;
            end
          end
          Token := Token + 1
          i := i + Len + 1
          Len := Keywords[i] - 48
        end
        Token := tkAnIdent
      else
        if Ch = 60/* < */ begin
          NextChar()
          //Token := 82/* R < */
          if Ch = 60/* < */ begin
            NextChar()
            Token := 85/* A << */
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
                Token := 97/* a := */
              end
            else
              if Ch = 45/* - */ begin
                NextChar()
                //Token := 67/* C */
                if Ch = 62/* > */ begin
                  NextChar()
                  Token := 98/* b -> */
                end
              else
                if Ch = 46/* . */ begin
                  NextChar()
                  //Token := 46/* . */
                  if Ch = 46/* . */ begin
                    NextChar()
                    Token := 99/* c .. */
                  end
                else
                  // case for ()+,;=[]
                  NextChar()
                end
              end
            end
          end
        end
      end
    end
  end
end



begin
  BufSize       := 65536
  Buf           := BrkAlloc(BufSize + 16)
  SymsHead      := BufSize
  LineNo        := 1
  CodePos       := 0

  DigitBuf16    := Buf[BufSize .. ]

  NextChar()
  GetToken()
  while Token <> 0 begin
    GetToken()
    PrintNumber(Token);
    PosixWrite(2, ''0D0A, 2)
  end
end.


