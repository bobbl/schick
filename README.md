The Programming Language Schick
===============================

A programming language where I can try my great ideas.



Bootstrap Schick
----------------

Bootstrap Schick is a small subset of Schick that can compile itself.
There is also a C99 implementation for bootstrapping.

The Syntax of Bootstrap Schick in Extended Backus-Naur Form (ENBF):

    Digit      = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" .
    Letter     = "A" | "B" | ... | "Z" | "a" | "b" | ... | "z" | "_" | "#" .
    IdChar     = Digit | Letter .
    Identifier = PureLetter { IdChar } .
    Num        = Digit { Digit } .

    AnyChar    = 1 | 2 | ... | 9 | 11 | 12 | ... | 38 | 40 | 41 | ... | 255 .
    CharString = "'" { AnyChar } "'" .
    HexLetter  = Digit | "A" | "B" | ... | "F" .
    HexString  = HexLetter HexLetter { HexLetter HexLetter } .
    Str        = CharString { HexString CharString } { HexString } .

    ArithOp     = "+" | "-" | "*" | "/" | "%" | "&" | "|" | "^" | "<<" | ">>" .
    CompareOp   = "=" | "<>" | "<" | ">" | "<=" | ">=" .
    Type        = "number" | "[" "]" "byte" .

    Expression  = Factor { ArithOp Factor } .
    ExprList    = Expression { "," Expression } .
    Call        = Identifier "(" [ ExprList ] ") .
    Symbol      = Identifier [ "[" Expression [ ".." ] ] .
    Brackets    = "(" Expression ")" .
    Factor      = Num | Str | Call | Symbol | Brackets.

    Condition   = Expression CompareOp Expression .
    If          = "if" Condition "begin" Sequence [ "else" Sequence ] "end" .
    While       = "while" Condition "begin" Sequence "end" .
    Return      = "return" [ Expression | ";" ] .
    AsmLine     = "." "string" Str .
    Asm         = "#asm" { AsmLine } "end" .
    Variable    = Identifier ":" Type .
    LocalVar    = Variable [ ":=" Expression ] .
    Assignment  = Identifier [ "[" Expression "]" ] ":=" Expression .
    Statement   = If | While | Return | Asm | LocalVar | Call | Assignment .

    Sequence    = { Statement [ ";" ] }
    BasicBlock  = "begin" Sequence "end" .
    Body        = BasicBlock | "#forward
    ParamList   = Variable { "," Variable } .
    Procedure   = "procedure" Identifier "(" [ ParamList ] ")" [ ":" Type ] [ ";" ] Body .
    Constant    = Identifier [ ":" Type ] "=" Integer .
    Declaration = Constant | Variable | Procedure .
    Module      = "module" Identifier [ ";" ] { Declaration  [ ";" ] } BasicBlock "." .

