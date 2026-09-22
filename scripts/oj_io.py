#!/usr/bin/env python3
"""Shared local/OJ testcase serialization and comparison.

Export one numbered input/answer pair: oj_io.py CASE --out DIR --id 1
The OJ package's grading configuration is maintained separately.
"""
import argparse
import re
from pathlib import Path

RAM_BYTES = 256 * 1024 * 1024


def validate_image(text):
    address = 0
    for line in text.splitlines():
        for token in line.split('//', 1)[0].split('#', 1)[0].split():
            location = token.startswith('@')
            digits = token[1:] if location else token
            if not re.fullmatch(r'[0-9a-fA-F]+', digits):
                raise ValueError(f'invalid image token: {token}')
            value = int(digits, 16)
            if location:
                if value >= RAM_BYTES:
                    raise ValueError('image address out of range')
                address = value
            else:
                if value > 255 or address >= RAM_BYTES:
                    raise ValueError('image byte/address out of range')
                address += 1


def prepare_case(case, max_cycles, latency):
    """Return the exact .in/.ans strings used both locally and by OJ."""
    if not 1 <= max_cycles < 2**63 or not 1 <= latency <= 1_000_000:
        raise ValueError('invalid cycle limit or latency')
    image = (case / 'program.data').read_text()
    validate_image(image)
    result = int((case / 'expected.txt').read_text().strip(), 0)
    if not 0 <= result <= 0xffffffff:
        raise ValueError('expected result must be an unsigned 32-bit value')
    return (f'CPU2026-OJ 1\n{max_cycles} {latency}\n{image.rstrip()}\n',
            f'{result}\n')


def normalized(text):
    # ACMOJ's default compare ignores trailing whitespace and blank lines.
    return [line.rstrip() for line in text.splitlines() if line.strip()]


def compare_output(actual, expected):
    """Return None on success, otherwise a diagnostic; do not ignore extra output."""
    got, want = normalized(actual), normalized(expected)
    if got == want:
        return None
    if not got:
        return 'no simulator output'
    if got[0] != want[0]:
        return f'exit result mismatch: expected {want[0]}, actual {got[0]}'
    return f'output length mismatch: expected {len(want)} lines, actual {len(got)}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('case', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--id', type=int, default=1)
    parser.add_argument('--max-cycles', type=int, default=1_000_000)
    parser.add_argument('--latency', type=int, default=10)
    args = parser.parse_args()
    if args.id < 1:
        parser.error('--id must be positive')
    try:
        data, answer = prepare_case(args.case, args.max_cycles, args.latency)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / f'{args.id}.in').write_text(data)
    (args.out / f'{args.id}.ans').write_text(answer)


if __name__ == '__main__':
    main()
