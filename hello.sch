module Hello;

import posix;

begin
  posix.write(1, 'Hello world'0D0A, 13);
end.
