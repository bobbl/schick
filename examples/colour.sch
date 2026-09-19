module Colour;

procedure PosixWrite(FileDesc: number, Buf: []byte, Len: number)
begin
  #asm
    .string ''93080004  /* li a7, 64 # sys_write        */
    .string ''73000000  /* ecall                        */
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


begin
  if PosixNotATTY(0) <> 0 begin
    PosixWrite(1, 'stdin is NOT a TTY. Stay grey.'0D0A, 32)
  else
    PosixWrite(1, 'stdin is a TTY. Use '1B'[1;33mcolours'1B'[0m.'0D0A, 41);
  end
end.
