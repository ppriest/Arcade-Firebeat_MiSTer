#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The state dump's register lists (docs/STATE.md), generated into each module.

For every always_ff block of a module (begin ... end, clocked), the registers it assigns become
one list: a word each, wider ones split into 32-bit words, arrays of up to 32 elements expanded.
The module gets, between the markers `// st_lists: begin` and `// st_lists: end` (placed before
`endmodule`), the lists as macros and a read mux on st_a/st_d; each block gets, before its closing
`end`, a Verilator-only write case on st_we/st_wd (sim/boot_tb +state). Re-running replaces both.

    python scripts/st_lists.py            write every module in MODULES
    python scripts/st_lists.py --check    exit 1 if a module's file is not what this would write

A register that must not be in the dump (a RAM, a constant, a pulse the dump never sees high) goes
in the module's `skip`; say why there or in docs/STATE.md.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# module file, address bits of st_a, names left out
MODULES = {
    'rtl/board/fb_spu.sv':       dict(abits=7, skip={'dongle', 'dg_q'}),
    'rtl/board/fb_rtc65271.sv':  dict(abits=6, skip={'regs', 'xmem', 'xq', 'rreg', 'xr_q', 'r'}),
    'rtl/board/fb_flash.sv':     dict(abits=6, skip=set()),
    'rtl/board/fb_pc16552.sv':   dict(abits=5, skip=set()),
    'rtl/board/fb_gcu_shell.sv': dict(abits=6, skip=set()),
    'rtl/board/fb_ppc_dma.sv':   dict(abits=8, skip={'sim_words', 'sim_dropped', 'sim_live', 'sim_gcu_wait', 'sim_src_wait'}),
}

BEGIN, END = '// st_lists: begin', '// st_lists: end'
WBEGIN, WEND = '`ifdef VERILATOR  // st_lists: write', '`endif  // st_lists: write'


def strip_comments(line):
    return re.sub(r'//.*', '', line)


def params(text):
    """localparam/parameter int and logic values usable in widths."""
    p = {}
    for m in re.finditer(r'\b(?:localparam|parameter)\s+(?:int|logic(?:\s*\[[^\]]*\])?)?\s*([^;]*);', text):
        for part in m.group(1).split(','):
            mm = re.match(r'\s*(\w+)\s*=\s*([\w\'_ +\-*()]+)\s*$', part)
            if mm:
                v = mm.group(2).replace('_', '')
                v = re.sub(r"\d+'[dD](\d+)", r'\1', v)
                v = re.sub(r"\d+'[hH]([0-9a-fA-F]+)", r'0x\1', v)
                try:
                    p[mm.group(1)] = int(eval(v, {}, dict(p)))
                except Exception:
                    pass
    return p


def ev(expr, p):
    return int(eval(expr, {}, dict(p)))


def decls(text, p):
    """name -> (width, array length or 0, enum type or None)"""
    enums = set(re.findall(r'typedef\s+enum\b[^{]*\{[^}]*\}\s*(\w+)\s*;', text))
    d = {}
    for raw in text.split('\n'):
        line = strip_comments(raw).strip()
        if line.startswith('input'):
            continue
        if line.startswith('output') and not line.endswith((',', ';')):
            line += ','
        m = re.match(r'(?:output\s+)?(logic|reg|bit|wire|(\w+))\s*((?:\[[^\]]+\])*)\s*(.*)[;,]$', line)
        if not m or line.startswith(('typedef', 'localparam', 'parameter', 'assign', 'return')):
            continue
        typ = m.group(1)
        if typ not in ('logic', 'reg', 'bit') and typ not in enums:
            continue
        dims = [abs(ev(a, p) - ev(b, p)) + 1 for a, b in re.findall(r'\[([^\]:]+):([^\]]+)\]', m.group(3))]
        # a packed array ([n-1:0][w-1:0]) is listed by element, as an unpacked one
        outer = dims[0] if len(dims) > 1 else 0
        w = 1
        for x in dims[1 if outer else 0:]:
            w *= x
        for v in m.group(4).split(','):
            vm = re.match(r'\s*(\w+)\s*(?:\[([^\]]+)\])?\s*(?:=.*)?$', v)
            if not vm:
                continue
            n = outer
            if vm.group(2):
                n = ev(vm.group(2), p) if ':' not in vm.group(2) else None
            d[vm.group(1)] = (w if typ in ('logic', 'reg', 'bit') else 4, n, typ if typ in enums else None)
    return d


def blocks(lines):
    """(first line, closing-end line) of each `always_ff ... begin` block, 0-based"""
    out = []
    i = 0
    while i < len(lines):
        if re.match(r'\s*always_ff\b.*\bbegin\b', strip_comments(lines[i])):
            depth = 0
            for j in range(i, len(lines)):
                l = strip_comments(lines[j])
                if lines[j].startswith(WBEGIN):
                    continue
                depth += len(re.findall(r'\b(begin|case|casez|casex|fork)\b', l))
                depth -= len(re.findall(r'\b(end|endcase|join)\b', l))
                if depth == 0:
                    out.append((i, j))
                    i = j
                    break
        i += 1
    return out


def entries(names, d):
    out = []
    for n in names:
        w, arr, enum = d[n]
        idx = [''] if not arr else ['[%d]' % k for k in range(arr)]
        for ix in idx:
            if enum:
                out.append(('%s%s' % (n, ix), enum))
            elif w <= 32:
                out.append(('%s%s' % (n, ix), None))
            else:
                for lo in range(0, w, 32):
                    out.append(('%s%s[%d:%d]' % (n, ix, min(lo + 31, w - 1), lo), None))
    return out


def generate(path, cfg):
    src = (ROOT / path).read_text()
    nl = '\r\n' if '\r\n' in src else '\n'
    text = src.replace('\r\n', '\n')
    # drop what an earlier run wrote
    text = re.sub(r'\n*' + re.escape(BEGIN) + r'.*?' + re.escape(END) + r'\n*', '\n\n', text, flags=re.S)
    text = re.sub(re.escape(WBEGIN) + r'.*?' + re.escape(WEND) + r'\n', '', text, flags=re.S)
    mod = re.search(r'\bmodule\s+(\w+)', text).group(1)
    p = params(text)
    d = decls(text, p)
    lines = text.split('\n')
    bl = blocks(lines)
    lists, addr, missing = [], 0, []
    for k, (a, b) in enumerate(bl):
        body = '\n'.join(strip_comments(l) for l in lines[a:b + 1])
        names = []
        for m in re.finditer(r'(?<![<>=!])\b(\w+)\s*(?:\[[^\]\n;=()]*(?:\[[^\]\n;=()]*\][^\]\n;=()]*)?\])*\s*<=', body):
            n = m.group(1)
            # a statement, not a comparison: after ';', 'begin', 'else', ':', ')' or a block's start
            before = body[:m.start()].rstrip()
            if not (before == '' or before.endswith((';', ':', ')')) or re.search(r'\b(begin|else)$', before)):
                continue
            if n in cfg['skip'] or n in names:
                continue
            if n not in d:
                missing.append(n)
                continue
            if d[n][1] is None or (d[n][1] or 0) > 32:
                missing.append(n + ' (array)')
                continue
            names.append(n)
        e = entries(names, d)
        lists.append([(addr + i, x, en) for i, (x, en) in enumerate(e)])
        addr += len(e)
    if addr > (1 << cfg['abits']):
        sys.exit('%s: %d words, more than st_a holds' % (path, addr))
    if missing:
        sys.exit('%s: no declaration for %s' % (path, ', '.join(sorted(set(missing)))))
    aw = cfg['abits']
    tag = mod.upper()

    def lit(a):
        return "%d'h%X" % (aw, a)
    # write cases, from the last block up so line numbers hold
    for k in reversed(range(len(bl))):
        if not lists[k]:
            continue
        a, b = bl[k]
        ind = re.match(r'(\s*)', lines[b]).group(1) + '    '
        w = [WBEGIN, ind + 'if (st_we) case (st_a)']
        for ad, x, en in lists[k]:
            if en:
                w.append(ind + '%s: %s <= %s\'(st_wd[%d:0]);' % (lit(ad), x, en, d[x.split('[')[0]][0] - 1))
            else:
                w.append(ind + '%s: %s <= ($bits(%s))\'(st_wd);' % (lit(ad), x, x))
        w += [ind + 'default: ;', ind + 'endcase', WEND]
        lines[b:b] = w
    text = '\n'.join(lines)
    rd = [BEGIN,
          '// [Firebeat] The state dump\'s register block (docs/STATE.md), generated by scripts/st_lists.py:',
          '// a word a register, in the order of its always_ff block; written in Verilator only.',
          'always_comb begin',
          '    st_d = 32\'d0;',
          '    case (st_a)']
    for lst in lists:
        for ad, x, en in lst:
            rd.append('    %s: st_d = 32\'(%s);' % (lit(ad), x))
    rd += ['    default: ;', '    endcase', 'end', END]
    i = text.rindex('endmodule')
    text = text[:i].rstrip('\n') + '\n\n' + '\n'.join(rd) + '\n\n' + text[i:]
    return text.replace('\n', nl), src, addr, [[x for _, x, _ in l] for l in lists]


def main():
    check = '--check' in sys.argv
    bad = False
    for path, cfg in MODULES.items():
        new, old, n, lists = generate(path, cfg)
        if check:
            if new != old:
                print('%s: out of date' % path)
                bad = True
        else:
            (ROOT / path).write_bytes(new.encode())
            print('%s: %d words: %s' % (path, n, ' | '.join(', '.join(l) for l in lists)))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
