module AToI

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

procedure PosixWrite(FileDesc: number, Buf: string, Len: number)
begin
  #asm
    .string ''93080004  //    li a7, 64         # sys_write
    .string ''73000000  //    ecall
  end
end

procedure PosixRead(FileDesc: number, Buf: string, Len: number)
begin
  #asm
    .string ''9308F003  //    li a7, 63         # sys_read
    .string ''73000000  //    ecall
  end
end



var
  DigitBuf16 : string 

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
    PosixWrite(2, DigitBuf16[i ... ], 16 - i)
  end
end


begin
  DigitBuf16 := BrkAlloc(16)
  PrintNumber(98765);
  PosixWrite(2, ''0D0A, 2)
end.


