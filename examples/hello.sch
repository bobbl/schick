module Hello;

procedure PosixWrite(FileDesc: number, Buf: string, Len: number)
begin
  #asm
    .string ''93080004  /* li a7, 64 # sys_write        */
    .string ''73000000  /* ecall                        */
  end;
end;

begin
  PosixWrite(1, 'Hello world'0D0A, ((10 + 3) * 2) >> 1);
  i : number := 0;
  while i < 5 begin
    if (i & 1) = 0 begin
      PosixWrite(1, 'even'0D0A, 6);
    else
      PosixWrite(1, 'odd'0D0A, 5);
    end;
    i := i + 1;
  end;
end.
