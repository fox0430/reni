#!/usr/bin/env python3
"""Port test_syntax.c to JSON for reni benchmark.

Extracts x2/x3/n/e tests from PERL and PERL_NG syntax modes only.
"""

import re
import json


def parse_c_string(s):
    """Parse a C string literal (handling escapes) to bytes."""
    result = bytearray()
    i = 0
    while i < len(s):
        if s[i] == '\\':
            i += 1
            if i >= len(s):
                break
            c = s[i]
            if c == 'n': result.append(0x0A)
            elif c == 't': result.append(0x09)
            elif c == 'r': result.append(0x0D)
            elif c == 'a': result.append(0x07)
            elif c == 'b': result.append(0x08)
            elif c == 'e': result.append(0x1B)
            elif c == 'f': result.append(0x0C)
            elif c == 'v': result.append(0x0B)
            elif c == '\\': result.append(0x5C)
            elif c == '"': result.append(0x22)
            elif c == '\'': result.append(0x27)
            elif c == 'x':
                hex_str = ''
                i += 1
                while i < len(s) and len(hex_str) < 2 and s[i] in '0123456789abcdefABCDEF':
                    hex_str += s[i]
                    i += 1
                result.append(int(hex_str, 16) if hex_str else 0)
                continue
            elif c in '01234567':
                oct_str = c
                i += 1
                while i < len(s) and len(oct_str) < 3 and s[i] in '01234567':
                    oct_str += s[i]
                    i += 1
                result.append(int(oct_str, 8))
                continue
            else:
                result.append(ord('\\'))
                result.append(ord(c))
            i += 1
        else:
            result.extend(s[i].encode('utf-8'))
            i += 1
    return bytes(result)


def extract_string(args, start=0):
    """Extract a C string from args. Returns (parsed_string, next_pos)."""
    while start < len(args) and args[start] in ' \t\n':
        start += 1
    if start >= len(args) or args[start] != '"':
        return None, start
    raw = ''
    while start < len(args) and args[start] == '"':
        start += 1
        while start < len(args):
            if args[start] == '\\' and start + 1 < len(args):
                raw += args[start:start+2]
                start += 2
            elif args[start] == '"':
                start += 1
                break
            else:
                raw += args[start]
                start += 1
        while start < len(args) and args[start] in ' \t\n':
            start += 1
    return raw, start


def extract_int(args, start=0):
    while start < len(args) and args[start] in ' \t\n,':
        start += 1
    neg = False
    if start < len(args) and args[start] == '-':
        neg = True
        start += 1
    num = ''
    while start < len(args) and args[start].isdigit():
        num += args[start]
        start += 1
    if num:
        return (-int(num) if neg else int(num)), start
    return None, start


def skip_comma(args, start):
    while start < len(args) and args[start] in ' \t\n,':
        start += 1
    return start


def parse_call(line, line_no):
    """Parse a single x2/x3/n/e call."""
    s = line.strip()
    # Strip trailing comments
    in_str = False
    for i, c in enumerate(s):
        if c == '"' and (i == 0 or s[i-1] != '\\'):
            in_str = not in_str
        elif not in_str and s[i:i+2] == '//':
            s = s[:i].strip()
            break

    for kind in ('x2', 'x3'):
        m = re.match(rf'^{kind}\s*\(', s)
        if not m:
            continue
        args = s[m.end():].rstrip(');').rstrip(')')
        pat, pos = extract_string(args)
        if pat is None: return None
        pos = skip_comma(args, pos)
        subj, pos = extract_string(args, pos)
        if subj is None: return None
        pos = skip_comma(args, pos)
        frm, pos = extract_int(args, pos)
        pos = skip_comma(args, pos)
        to, pos = extract_int(args, pos)
        t = {
            'kind': kind,
            'pattern': parse_c_string(pat).hex(),
            'subject': parse_c_string(subj).hex(),
            'from': frm, 'to': to, 'line': line_no,
        }
        if kind == 'x3':
            pos = skip_comma(args, pos)
            mem, _ = extract_int(args, pos)
            t['mem'] = mem
        return t

    m = re.match(r'^n\s*\(', s)
    if m:
        args = s[m.end():].rstrip(');').rstrip(')')
        pat, pos = extract_string(args)
        if pat is None: return None
        pos = skip_comma(args, pos)
        subj, _ = extract_string(args, pos)
        if subj is None: return None
        return {
            'kind': 'n',
            'pattern': parse_c_string(pat).hex(),
            'subject': parse_c_string(subj).hex(),
            'line': line_no,
        }

    m = re.match(r'^e\s*\(', s)
    if m:
        args = s[m.end():].rstrip(');').rstrip(')')
        pat, pos = extract_string(args)
        if pat is None: return None
        pos = skip_comma(args, pos)
        subj, pos = extract_string(args, pos)
        if subj is None: return None
        pos = skip_comma(args, pos)
        err = args[pos:].strip()
        return {
            'kind': 'e',
            'pattern': parse_c_string(pat).hex(),
            'subject': parse_c_string(subj).hex(),
            'error': err, 'line': line_no,
        }
    return None


def extract_func_tests(lines, func_name):
    """Extract tests from a named function."""
    tests = []
    in_func = False
    brace_depth = 0
    found_brace = False
    for i, line in enumerate(lines):
        s = line.strip()
        if not in_func:
            if re.match(rf'static\s+int\s+{func_name}\s*\(', s):
                in_func = True
                brace_depth = 0
                found_brace = False
            continue
        brace_depth += s.count('{') - s.count('}')
        if '{' in s:
            found_brace = True
        if found_brace and brace_depth <= 0:
            break
        t = parse_call(s, i + 1)
        if t:
            tests.append(t)
    return tests


def main():
    with open('vendor/oniguruma/test/test_syntax.c') as f:
        lines = f.readlines()

    # Extract from helper functions (called under PERL mode)
    helpers = [
        'test_reluctant_interval', 'test_possessive_interval',
        'test_isolated_option', 'test_prec_read',
        'test_look_behind', 'test_char_class',
    ]
    tests = []
    for name in helpers:
        h = extract_func_tests(lines, name)
        tests.extend(h)
        print(f'  {name}: {len(h)} tests')

    # PERL inline tests in main() (between Syntax=PERL and Syntax=JAVA)
    perl_inline = 0
    in_perl = False
    for i, line in enumerate(lines):
        s = line.strip()
        if 'Syntax = ONIG_SYNTAX_PERL;' in s:
            in_perl = True
            continue
        if 'Syntax = ONIG_SYNTAX_JAVA;' in s:
            in_perl = False
            continue
        if in_perl and not re.match(r'test_\w+\(\)', s):
            t = parse_call(s, i + 1)
            if t:
                tests.append(t)
                perl_inline += 1
    print(f'  perl_inline: {perl_inline} tests')

    # PERL_NG tests in main()
    perl_ng = 0
    in_ng = False
    for i, line in enumerate(lines):
        s = line.strip()
        if 'Syntax = ONIG_SYNTAX_PERL_NG;' in s:
            in_ng = True
            continue
        if in_ng and ('fprintf' in s or 'onig_' in s):
            break
        if in_ng:
            t = parse_call(s, i + 1)
            if t:
                tests.append(t)
                perl_ng += 1
    print(f'  perl_ng: {perl_ng} tests')

    print(f'Total: {len(tests)} tests')

    with open('tests/data/oniguruma_syntax.json', 'w') as f:
        json.dump({'source': 'test_syntax.c', 'count': len(tests), 'tests': tests}, f, indent=2)
    print('Written to tests/data/oniguruma_syntax.json')


if __name__ == '__main__':
    main()
