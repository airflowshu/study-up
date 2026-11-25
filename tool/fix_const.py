"""把「含动态色引用的 const 构造」降级为非 const。

AppColors 从 static const 改成静态 getter 之后，凡是写在 const 构造里的
`AppColors.xxx` 都不再是常量表达式。这里用括号平衡定位每个 const 的作用范围，
只删真正受影响的那部分，其余 const 原样保留。
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib')
DYNAMIC = 'AppColors.'

# 这些成员仍然是 const，允许出现在 const 上下文里
CONST_MEMBERS = ('childPalette', 'subjectPalette')


def strip_noise(src):
    """把字符串和注释替换成等长空格，保证下标与原文件一致。"""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out[i] = ' '
                i += 1
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            while i < n and not (src[i] == '*' and i + 1 < n and src[i + 1] == '/'):
                out[i] = ' ' if src[i] != '\n' else '\n'
                i += 1
            for k in range(i, min(i + 2, n)):
                out[k] = ' '
            i += 2
        elif c in "'\"":
            quote = c
            triple = src[i:i + 3] == quote * 3
            delim = quote * 3 if triple else quote
            for k in range(len(delim)):
                out[i + k] = ' '
            i += len(delim)
            while i < n:
                if src[i] == '\\':
                    out[i] = ' '
                    if i + 1 < n:
                        out[i + 1] = ' ' if src[i + 1] != '\n' else '\n'
                    i += 2
                    continue
                if src.startswith(delim, i):
                    for k in range(len(delim)):
                        out[i + k] = ' '
                    i += len(delim)
                    break
                out[i] = ' ' if src[i] != '\n' else '\n'
                i += 1
        else:
            i += 1
    return ''.join(out)


OPEN = {'(': ')', '[': ']', '{': '}'}


def match_close(clean, start):
    """clean[start] 是左括号，返回配对右括号的下标。"""
    stack = []
    i, n = start, len(clean)
    while i < n:
        ch = clean[i]
        if ch in OPEN:
            stack.append(OPEN[ch])
        elif ch in ')]}':
            if not stack or stack[-1] != ch:
                return -1
            stack.pop()
            if not stack:
                return i
        i += 1
    return -1


def find_scope(clean, pos):
    """const 关键字之后，返回它作用的结束下标；返回 None 表示这是常量声明。"""
    i, n = pos, len(clean)
    while i < n and clean[i].isspace():
        i += 1
    if i >= n:
        return None
    if clean[i] in '([{':
        end = match_close(clean, i)
        return end if end > 0 else None
    if clean[i] == '<':
        depth, j = 0, i
        while j < n:
            if clean[j] == '<':
                depth += 1
            elif clean[j] == '>':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        while j < n and clean[j].isspace():
            j += 1
        if j < n and clean[j] in '([{':
            end = match_close(clean, j)
            return end if end > 0 else None
        return None
    # 标识符（构造名），可能带泛型
    m = re.match(r'[A-Za-z_][A-Za-z0-9_]*', clean[i:])
    if not m:
        return None
    j = i + m.end()
    while j < n and clean[j].isspace():
        j += 1
    if j < n and clean[j] == '<':
        depth = 0
        while j < n:
            if clean[j] == '<':
                depth += 1
            elif clean[j] == '>':
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        while j < n and clean[j].isspace():
            j += 1
    if j < n and clean[j] == '(':
        end = match_close(clean, j)
        return end if end > 0 else None
    return None


def has_dynamic(segment):
    """segment 里是否引用了非 const 的 AppColors 成员。"""
    for m in re.finditer(re.escape(DYNAMIC), segment):
        tail = segment[m.end():]
        name = re.match(r'[A-Za-z_][A-Za-z0-9_]*', tail)
        if not name:
            continue
        if name.group(0) in CONST_MEMBERS:
            continue
        return True
    return False


def process(path):
    src = open(path, encoding='utf-8').read()
    if DYNAMIC not in src:
        return 0
    clean = strip_noise(src)
    removals = []
    for m in re.finditer(r'\bconst\b', clean):
        # const 前面必须是空白或分隔符，避免匹配到 contain 之类的子串
        prev = clean[m.start() - 1] if m.start() > 0 else ' '
        if not (prev.isspace() or prev in '([{,:'):
            continue
        end = find_scope(clean, m.end())
        if end is None:
            continue
        if has_dynamic(clean[m.start():end + 1]):
            removals.append(m.start())
    if not removals:
        return 0
    out = src
    for pos in sorted(removals, reverse=True):
        seg_end = pos + 5
        while seg_end < len(out) and out[seg_end] == ' ':
            seg_end += 1
        out = out[:pos] + out[seg_end:]
    open(path, 'w', encoding='utf-8').write(out)
    return len(removals)


def main():
    total, files = 0, 0
    for dirpath, _, names in os.walk(ROOT):
        for name in names:
            if not name.endswith('.dart'):
                continue
            if name == 'theme.dart':
                # 主题文件手工维护，脚本不动
                continue
            p = os.path.join(dirpath, name)
            c = process(p)
            if c:
                total += c
                files += 1
                print(f'{os.path.relpath(p, ROOT)}: 去掉 {c} 个 const')
    print(f'共 {files} 个文件，{total} 处')


if __name__ == '__main__':
    main()
