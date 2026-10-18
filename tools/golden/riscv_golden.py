#!/usr/bin/env python3
"""Sequential RV32IM golden model for the course testcases.

The model reads the same byte-addressed ``program.data`` format as the course
simulator (``@address`` followed by hex byte tokens), executes from PC 0, and
stops on the course exit protocol: a word store to ``0x8000_0000``.

Commit trace format (one line per retired instruction)::

    pc rd value

``pc`` and ``value`` are 8-digit lowercase hex; ``rd`` is decimal.  ``rd`` is 0
when the instruction does not write a register.  ``value`` is the writeback
value for register writes, the store data for stores, the resolved target for
branches/jumps, and 0 otherwise.  This is intentionally simple so the RTL
``LOCAL_TRACE`` output can use the same format.

Usage:
    python3 tools/golden/riscv_golden.py testcases/correctness_gcd/program.data
    python3 tools/golden/riscv_golden.py ... --expected .../expected.txt
    python3 tools/golden/riscv_golden.py ... --trace build/golden.trace
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

EXIT_ADDRESS = 0x8000_0000
MASK32 = 0xFFFF_FFFF


def u32(value: int) -> int:
    return value & MASK32


def s32(value: int) -> int:
    value &= MASK32
    return value - (1 << 32) if value & (1 << 31) else value


def sign_extend(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    value &= (1 << bits) - 1
    return (value ^ sign) - sign


def bits(inst: int, hi: int, lo: int) -> int:
    return (inst >> lo) & ((1 << (hi - lo + 1)) - 1)


class Image:
    """Sparse byte-addressed memory loaded from program.data / .bin."""

    def __init__(self) -> None:
        self.mem: dict[int, int] = {}

    @classmethod
    def load(cls, path: Path) -> "Image":
        image = cls()
        if path.suffix == ".bin":
            for offset, byte in enumerate(path.read_bytes()):
                image.mem[offset] = byte
            return image
        address = 0
        for line in path.read_text().splitlines():
            line = line.split("//", 1)[0].split("#", 1)[0]
            for token in line.split():
                if token.startswith("@"):
                    address = int(token[1:], 16)
                    continue
                if not token or any(c not in "0123456789abcdefABCDEF" for c in token):
                    raise ValueError(f"invalid image token: {token}")
                value = int(token, 16)
                if value > 0xFF:
                    raise ValueError(f"image byte out of range: {token}")
                image.mem[address] = value
                address += 1
        return image

    def read_u8(self, address: int) -> int:
        return self.mem.get(address & MASK32, 0)

    def read_u16(self, address: int) -> int:
        return self.read_u8(address) | (self.read_u8(address + 1) << 8)

    def read_u32(self, address: int) -> int:
        return (self.read_u8(address) |
                (self.read_u8(address + 1) << 8) |
                (self.read_u8(address + 2) << 16) |
                (self.read_u8(address + 3) << 24))

    def write_u8(self, address: int, value: int) -> None:
        self.mem[address & MASK32] = value & 0xFF

    def write_u16(self, address: int, value: int) -> None:
        self.write_u8(address, value)
        self.write_u8(address + 1, value >> 8)

    def write_u32(self, address: int, value: int) -> None:
        for i in range(4):
            self.write_u8(address + i, value >> (8 * i))


class CPU:
    def __init__(self, image: Image, trace=None, max_instructions: int = 10_000_000):
        self.image = image
        self.regs = [0] * 32
        self.pc = 0
        self.instructions = 0
        self.trace = trace
        self.max_instructions = max_instructions
        self.result: int | None = None

    def read_reg(self, index: int) -> int:
        return 0 if index == 0 else self.regs[index]

    def write_reg(self, index: int, value: int) -> None:
        if index != 0:
            self.regs[index] = u32(value)

    def fetch(self) -> int:
        return self.image.read_u32(self.pc)

    def step(self) -> bool:
        """Execute one instruction.  Returns False after the exit store."""
        pc = self.pc
        inst = self.fetch()
        opcode = inst & 0x7F
        rd = bits(inst, 11, 7)
        funct3 = bits(inst, 14, 12)
        rs1 = bits(inst, 19, 15)
        rs2 = bits(inst, 24, 20)
        funct7 = bits(inst, 31, 25)
        a = self.read_reg(rs1)
        b = self.read_reg(rs2)
        next_pc = u32(pc + 4)
        rd_write = False
        value = 0
        trace_value = 0

        imm_i = sign_extend(bits(inst, 31, 20), 12)
        imm_s = sign_extend((bits(inst, 31, 25) << 5) | bits(inst, 11, 7), 12)
        imm_b = sign_extend((bits(inst, 31, 31) << 12) |
                            (bits(inst, 7, 7) << 11) |
                            (bits(inst, 30, 25) << 5) |
                            (bits(inst, 11, 8) << 1), 13)
        imm_u = inst & 0xFFFF_F000
        imm_j = sign_extend((bits(inst, 31, 31) << 20) |
                            (bits(inst, 19, 12) << 12) |
                            (bits(inst, 20, 20) << 11) |
                            (bits(inst, 30, 21) << 1), 21)

        if opcode == 0x37:        # LUI
            value = imm_u
            rd_write = True
        elif opcode == 0x17:      # AUIPC
            value = pc + imm_u
            rd_write = True
        elif opcode == 0x6F:      # JAL
            value = pc + 4
            rd_write = True
            next_pc = u32(pc + imm_j)
            trace_value = next_pc
        elif opcode == 0x67:      # JALR
            value = pc + 4
            rd_write = True
            next_pc = u32((a + imm_i) & ~1)
            trace_value = next_pc
        elif opcode == 0x63:      # BRANCH
            taken = {
                0: a == b,
                1: a != b,
                4: s32(a) < s32(b),
                5: s32(a) >= s32(b),
                6: a < b,
                7: a >= b,
            }.get(funct3, False)
            if funct3 not in (0, 1, 4, 5, 6, 7):
                self.illegal(pc, inst, "branch funct3")
            if taken:
                next_pc = u32(pc + imm_b)
            trace_value = next_pc if taken else u32(pc + 4)
        elif opcode == 0x03:      # LOAD
            address = u32(a + imm_i)
            if funct3 == 0:       # LB
                value = sign_extend(self.image.read_u8(address), 8)
            elif funct3 == 1:     # LH
                value = sign_extend(self.image.read_u16(address), 16)
            elif funct3 == 2:     # LW
                value = self.image.read_u32(address)
            elif funct3 == 4:     # LBU
                value = self.image.read_u8(address)
            elif funct3 == 5:     # LHU
                value = self.image.read_u16(address)
            else:
                self.illegal(pc, inst, "load funct3")
            rd_write = True
        elif opcode == 0x23:      # STORE
            address = u32(a + imm_s)
            if funct3 == 0:       # SB
                self.image.write_u8(address, b)
            elif funct3 == 1:     # SH
                self.image.write_u16(address, b)
            elif funct3 == 2:     # SW
                # The course exit protocol: word store to 0x8000_0000.
                if address == EXIT_ADDRESS:
                    self.result = u32(b)
                    self.instructions += 1
                    self.trace_line(pc, 0, u32(b))
                    return False
                self.image.write_u32(address, b)
            else:
                self.illegal(pc, inst, "store funct3")
            trace_value = u32(b)
        elif opcode == 0x13:      # OP-IMM
            shamt = bits(inst, 24, 20)
            if funct3 == 0:       # ADDI
                value = a + imm_i
            elif funct3 == 1:     # SLLI
                if funct7 != 0:
                    self.illegal(pc, inst, "SLLI funct7")
                value = a << shamt
            elif funct3 == 2:     # SLTI
                value = 1 if s32(a) < imm_i else 0
            elif funct3 == 3:     # SLTIU
                value = 1 if a < (imm_i & MASK32) else 0
            elif funct3 == 4:     # XORI
                value = a ^ imm_i
            elif funct3 == 5:     # SRLI / SRAI
                if funct7 == 0:
                    value = a >> shamt
                elif funct7 == 0x20:
                    value = s32(a) >> shamt
                else:
                    self.illegal(pc, inst, "shift funct7")
            elif funct3 == 6:     # ORI
                value = a | imm_i
            elif funct3 == 7:     # ANDI
                value = a & imm_i
            else:
                self.illegal(pc, inst, "OP-IMM funct3")
            rd_write = True
        elif opcode == 0x33:      # OP
            if funct7 == 0x01:    # M extension
                if funct3 == 0:   # MUL
                    value = a * b
                elif funct3 == 1: # MULH
                    value = (s32(a) * s32(b)) >> 32
                elif funct3 == 2: # MULHSU
                    value = (s32(a) * b) >> 32
                elif funct3 == 3: # MULHU
                    value = (a * b) >> 32
                elif funct3 == 4: # DIV
                    value = self.div_signed(a, b)
                elif funct3 == 5: # DIVU
                    value = MASK32 if b == 0 else a // b
                elif funct3 == 6: # REM
                    value = self.rem_signed(a, b)
                elif funct3 == 7: # REMU
                    value = a if b == 0 else a % b
            else:
                if funct3 == 0:
                    value = a - b if funct7 == 0x20 else a + b
                elif funct3 == 1:
                    if funct7 != 0:
                        self.illegal(pc, inst, "SLL funct7")
                    value = a << (b & 0x1F)
                elif funct3 == 2:
                    value = 1 if s32(a) < s32(b) else 0
                elif funct3 == 3:
                    value = 1 if a < b else 0
                elif funct3 == 4:
                    value = a ^ b
                elif funct3 == 5:
                    if funct7 == 0:
                        value = a >> (b & 0x1F)
                    elif funct7 == 0x20:
                        value = s32(a) >> (b & 0x1F)
                    else:
                        self.illegal(pc, inst, "SRA funct7")
                elif funct3 == 6:
                    value = a | b
                elif funct3 == 7:
                    value = a & b
                else:
                    self.illegal(pc, inst, "OP funct3")
                if funct7 not in (0x00, 0x20):
                    self.illegal(pc, inst, "OP funct7")
            rd_write = True
        elif opcode == 0x0F:      # FENCE / FENCE.I: no-op for this course
            pass
        else:
            self.illegal(pc, inst, "opcode")

        if rd_write:
            self.write_reg(rd, value)
            trace_value = u32(value)

        self.instructions += 1
        self.trace_line(pc, rd if rd_write else 0, trace_value)
        self.pc = next_pc
        if self.instructions >= self.max_instructions:
            raise RuntimeError(
                f"instruction limit {self.max_instructions} reached at pc=0x{self.pc:08x}"
            )
        return True

    def trace_line(self, pc: int, rd: int, value: int) -> None:
        if self.trace is not None:
            self.trace.write(f"{pc & MASK32:08x} {rd:0d} {value & MASK32:08x}\n")

    @staticmethod
    def div_signed(a: int, b: int) -> int:
        sa, sb = s32(a), s32(b)
        if sb == 0:
            return MASK32
        if sa == -(1 << 31) and sb == -1:
            return 0x8000_0000
        # Python // floors; RISC-V truncates toward zero.
        quotient = abs(sa) // abs(sb)
        if (sa < 0) != (sb < 0):
            quotient = -quotient
        return u32(quotient)

    @staticmethod
    def rem_signed(a: int, b: int) -> int:
        sa, sb = s32(a), s32(b)
        if sb == 0:
            return u32(a)
        if sa == -(1 << 31) and sb == -1:
            return 0
        quotient = abs(sa) // abs(sb)
        if (sa < 0) != (sb < 0):
            quotient = -quotient
        return u32(sa - quotient * sb)

    @staticmethod
    def illegal(pc: int, inst: int, why: str) -> None:
        raise RuntimeError(f"illegal instruction at pc=0x{pc:08x}: 0x{inst:08x} ({why})")

    def run(self) -> int:
        while self.step():
            pass
        assert self.result is not None
        return self.result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", type=Path, help="program.data or flat .bin")
    parser.add_argument("--trace", type=Path, help="write commit trace")
    parser.add_argument("--expected", type=Path, help="expected result file")
    parser.add_argument("--max-instructions", type=int, default=10_000_000)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    image = Image.load(args.image)
    trace_file = args.trace.open("w") if args.trace else None
    try:
        cpu = CPU(image, trace=trace_file, max_instructions=args.max_instructions)
        result = cpu.run()
    finally:
        if trace_file:
            trace_file.close()

    if not args.quiet:
        print(f"result={result} instructions={cpu.instructions}")
    if args.expected:
        expected_text = args.expected.read_text().strip()
        if not expected_text:
            raise SystemExit(f"empty expected file: {args.expected}")
        expected = int(expected_text.split()[0], 0)
        if result != expected:
            print(f"FAIL: result={result} expected={expected}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
