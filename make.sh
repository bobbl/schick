#!/bin/sh


help () {
    echo "Usage: $0 <task> ..."
    echo
    echo "  test_hello      Build bootstrap Schick compiler from C and run hello.sch"
    echo "  test_bootstrap  Compare Bootstrap Schick implementations in C and Schick" 
    echo "  test_punycc     Use PunyCC to build boottrap Schick compiler"
    echo
    echo "  build_compiler  Build all compilers from scratch"
    echo "  nightly         Build the nightly compiler"
    echo "  run <file>      Compile Schick file and execute it (using Nighly Schick)"
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

esc_green="\033[32m"
esc_red="\033[1;31m"
esc_orange="\033[33m"
esc="\033[0m"




# Use one compiler to build another compiler
# $1 uses this compiler
# $2 to build this compiler
#
# c C Schick
# b Bootstrap Schick
# n Nightly Schick
use_1_to_build_2 () {
    case $2 in
        b)  title="Bootstrap" ;;
        n)  title="Nightly" ;;
        *)  echo "Fatal: unknown compiler letter"
            exit
            ;;
    esac
    sname=../examples/${2}schick.sch
    dname=${2}schick.${1}.rv32
    rm -f $dname

    case $1 in
        c)  echo "Use C Schick to compile $title Schick"
            ./cschick.x < $sname  > $dname || exit
            ;;
        b)  echo "Use Bootstrap Schick to compile $title Schick"
            "$QEMU_RV32" ./bschick.c.rv32 < $sname  > $dname
            ;;
        n)  echo "Use Nightly Schick to compile $title Schick"
            "$QEMU_RV32" ./nschick.b.rv32 < $sname  > $dname || exit
            ;;
        *) echo "Fatal: unknown compiler letter"
           exit
           ;;
    esac
    chmod +x $dname
}


use_cc_to_build_c () {
    echo "Use $CC to compile C Schick"
    "$CC" -o cschick.x ../schick.c || exit
}


# build all compilers from scratch: c, bootstrap and nightly
build_compiler () {
    mkdir -p build
    cd build

    use_cc_to_build_c
    use_1_to_build_2 c b
    use_1_to_build_2 b n

    cd ..
}


# compare two RV32 binaries
# $1 filename 1
# $2 filename 2
compare () {
    echo "Compare"

    #od -Ax -tx1 -v bschick.rv32 > tmp.b.hex

    "$OBJDUMP_RV32" -b binary -m riscv -D "$1" | tail -n +3 > tmp.a.disasm
    "$OBJDUMP_RV32" -b binary -m riscv -D "$2" | tail -n +3 > tmp.b.disasm
    diff tmp.a.disasm tmp.b.disasm > tmp.diff
    lines=$(wc -l < tmp.diff)
    if [ $lines -lt 30 ]
    then
        diff --color tmp.a.disasm tmp.b.disasm
    else
        echo "${esc_red}Many differences${esc}"
    fi
}


test_bootstrap () {
    mkdir -p build
    cd build

    use_cc_to_build_c
    use_1_to_build_2 c b
    use_1_to_build_2 b b
    compare bschick.b.rv32 bschick.c.rv32

    cd ..
}


test_nightly () {
    mkdir -p build
    cd build

    use_1_to_build_2 b b
    use_1_to_build_2 n b
    compare bschick.b.rv32 bschick.n.rv32

    cd ..
}







# Compile and run a Schick file with the nightly compiler
# $1 Schick source file name
run () {
    elf=build/$(basename "$1" .sch).rv32
    "$QEMU_RV32" ./build/nschick.rv32 < "$1" > "$elf"
    if [ $? -eq 0 ]
    then
        chmod +x "$elf"
        "$QEMU_RV32" "$elf"
    fi
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
    "$QEMU_RV32" schick.punycc.rv32 < ../examples/hello.sch > hello.punycc.rv32
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

        test_nightly)
            test_nightly
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

        nightly)
            cd build
            "$QEMU_RV32" ./bschick.rv32 < ../examples/nschick.sch > nschick.rv32
            chmod +x nschick.rv32
            cd ..
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
