#!/bin/sh


help () {
    echo "Usage: $0 <task> ..."
    echo
    echo "  test_hello    Build bootstrap Schick compiler from C and run hello.sch"
    echo "  test_punycc   Use PunyCC to build boottrap Schick compiler"
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




# Compile hello.sch with compiler written in C
test_hello () {
    mkdir -p build
    cd build
    "$CC" -o schick.c.x ../schick.c
    ./schick.c.x < ../hello.sch > hello.rv32
    chmod +x hello.rv32
    "$QEMU_RV32" hello.rv32
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
        help|-h)        help ;;

        test_hello)     test_hello ;;
        test_punycc)    test_punycc ;;

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
