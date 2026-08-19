module Hello;

import posix;

begin
  posix.write(1, 'Hello world'0D0A, ((10 + 3) * 2) >> 1);
  i : number;
  i := 0;
  while i < 5 begin
    if (i & 1) = 0 begin
      posix.write(1, 'even'0D0A, 6);
    else
      posix.write(1, 'odd'0D0A, 5);
    end;
    i := i + 1;
  end;
end.
