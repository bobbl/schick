#!/bin/sh


help () {
    echo "Usage: $0 <task> ..."
    echo
    echo "  test_hello      Build bootstrap Schick compiler from C and run hello.sch"
    echo "  test_bootstrap  Compare Bootstrap Schick implementations in C and Schick" 
    echo "  test_punycc     Use PunyCC to build boottrap Schick compiler"
    echo "  run <file>    Compile Schick file and execute it"
    echo
    echo "Environment variables:"
    echo "  CC=           native C compiler (gcc or clang)"
    echo "  QEMU_RV32=    path to qemu-riscv32 (if not in the search path)"
}

if [ $# -eq 0 ] 
then
    help
    exit 1
fi


# paths to external tools
CC=${CC:-gcc}
QEMU_RV32=${QEMU_RV32:-qemu-riscv32}
OBJDUMP_RV32=${OBJDUMP_RV32:-riscv64-linux-gnu-objdump}


# build all compilers from scratch: c, bootstrap and nightly
build_compiler () {
    mkdir -p build
    cd build
    "$CC" -o cschick.x ../schick.c

    ./cschick.x < ../examples/bschick.sch > bschick.rv32
    chmod +x bschick.rv32

    "$QEMU_RV32" ./bschick.rv32 < ../examples/nschick.sch > nschick.rv32
    chmod +x nschick.rv32

    cd ..
}


# Compare 
test_bootstrap () {
    mkdir -p build
    cd build
    rm -f cschick.x bschick.rv32 tschick.rv32

    echo "Use $CC to compile C Schick"
    "$CC" -o cschick.x ../schick.c

    echo "Use C Schick to compile Bootstrap Schick"
    ./cschick.x < ../examples/bschick.sch > bschick.rv32 || exit
    chmod +x bschick.rv32

    echo "Use Bootstrap Schick to compile Bootstrap Schick"
    "$QEMU_RV32" ./bschick.rv32 < ../examples/bschick.sch > tschick.rv32
    chmod +x tschick.rv32

    echo "Compare"
    #od -Ax -tx1 -v bschick.rv32 > tmp.b.hex
    "$OBJDUMP_RV32" -b binary -m riscv -D bschick.rv32 | tail -n +3 > b.disasm
    "$OBJDUMP_RV32" -b binary -m riscv -D tschick.rv32 | tail -n +3 > t.disasm
    diff b.disasm t.disasm

    cd ..
}


# Compile and run a Schick file with the compiler written in C
# $1 Schick source file name
run () {
    mkdir -p build
    cd build
    "$CC" -o schick.c.x ../schick.c
    cd ..

    elf=build/$(basename "$1" .sch).rv32
    ./build/schick.c.x < "$1" > "$elf"
    chmod +x "$elf"
    "$QEMU_RV32" "$elf"
}


# Build bootstrap compiler written in C with punycc
test_punycc () {
    mkdir -p build
    cd build

    # fetch punycc
    if [ ! -d punycc ]
    then
        git clone https://github.com/bobbl/punycc.git
    fi

    # build punycc
    cd punycc
    ./make.sh rv32 test_self
    punycc="$(pwd)/build/punycc_rv32.rv32"
    cd ..

    cat punycc/host_rv32.c ../schick.c > schick.punycc.c
    ./punycc/build/punycc_rv32.rv32 < schick.punycc.c > schick.punycc.rv32
    echo Bootstrap Schick compiler size: $(wc -c < schick.punycc.rv32)

    chmod +x schick.punycc.rv32
    "$QEMU_RV32" schick.punycc.rv32 < ../hello.sch > hello.punycc.rv32
    chmod +x hello.punycc.rv32
    "$QEMU_RV32" hello.punycc.rv32
}


while [ $# -ne 0 ]
do
    case $1 in
        help|-h)
            help
            ;;

        test_bootstrap)
            test_bootstrap
            ;;

        test_hello)
            run examples/hello.sch
            ;;

        test_punycc)
            test_punycc
            ;;

        build_compiler)
            build_compiler
            ;;

        run)
            run "$2"
            shift
            ;;

        disasm)
            riscv64-linux-gnu-objdump -b binary -m riscv -D "$2"
            shift
            ;;

        clean)
            rm -rf build
            ;;

        *)
            echo "Unknown task $1. Stop."
            exit 1
            ;;
    esac
    shift
done





# SPDX-License-Identifier: ISC
