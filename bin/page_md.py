#!/usr/bin/env python3
"""page_md - HTML -> readable Markdown converter (stdlib only).
stdin: html; argv: [maxchars] [start-marker] [base-url]"""

import sys, re
from html.parser import HTMLParser
from urllib.parse import urljoin


class Headings:
    LEVEL = {'h1': '#', 'h2': '##', 'h3': '###', 'h4': '####', 'h5': '#####', 'h6': '######'}


class P(HTMLParser):
    # elements whose entire subtree we drop (renderer chrome, not content)
    SKIP = {'script', 'style', 'noscript', 'svg', 'template', 'head',
            'iframe', 'button', 'input', 'select', 'option', 'textarea', 'form'}
    # elements that start a new block/line
    BLOCK = {'p', 'div', 'section', 'article', 'header', 'figure',
             'figcaption', 'table', 'tr', 'dd', 'dt', 'details', 'summary'}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.skip = 0
        self.parts = []
        self.in_a = 0
        self.a_text = []
        self.a_href = None
        self.in_pre = 0
        self.in_code = 0
        self.lists = []          # stack: 'ul' | 'ol'
        self.ol_counters = []

    # ---- helpers -------------------------------------------------
    def newlines(self, n=1):
        self.parts.append('\n' * n)

    def open_markdown(self, tag):
        return {'strong': '**', 'b': '**', 'em': '*', 'i': '*',
                'blockquote': '\n> ',
                'hr': ''}.get(tag, '')

    # ---- parser events -------------------------------------------
    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
            return
        if self.skip:
            return
        a = dict(attrs)
        if tag in Headings.LEVEL:
            self.in_heading = True
            self.newlines(2)
            if not getattr(self, 'in_heading', False):
                self.parts.append(Headings.LEVEL[tag] + ' ')
        elif tag == 'a' and self.in_a == 0 and a.get('href'):
            self.in_a = 1
            self.a_text = []
            self.a_href = urljoin(self.base, a['href'])
        elif tag in ('ul', 'ol'):
            self.lists.append(tag)
            self.ol_counters.append(0)
        elif tag == 'li' and self.lists:
            depth = len(self.lists) - 1
            kind = self.lists[-1]
            if kind == 'ol':
                self.ol_counters[-1] += 1
                bullet = f'{self.ol_counters[-1]}. '
            else:
                bullet = '- '
            self.newlines(2)
            self.parts.append('  ' * depth + bullet)
        elif tag == 'blockquote':
            self.parts.append('\n> ')
        elif tag == 'pre':
            self.in_pre += 1
            self.newlines(2)
            if self.in_pre == 1:
                self.parts.append('```\n')
        elif tag == 'code' and not self.in_pre:
            self.in_code += 1
            self.parts.append('`')
        elif tag == 'br':
            self.newlines()
        elif tag == 'hr':
            self.newlines(2)
            self.parts.append('---')
            self.newlines(2)
        else:
            m = self.open_markdown(tag)
            if m:
                self.parts.append(m)
            if tag in self.BLOCK:
                self.newlines(1)

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skip = max(0, self.skip - 1)
            return
        if self.skip:
            return
        if tag in Headings.LEVEL:
            self.newlines(2)
        elif tag == 'a' and self.in_a:
            self.in_a = 0
            txt = ''.join(self.a_text).strip()
            if txt and self.a_href:
                self.parts.append(f'[{txt}]({self.a_href})')
            self.a_href = None
        elif tag in ('ul', 'ol'):
            self.lists.pop()
            self.ol_counters.pop()
            self.newlines(1)
        elif tag == 'pre':
            self.in_pre = max(0, self.in_pre - 1)
            if self.in_pre == 0:
                self.newlines()
                self.parts.append('```')
                self.newlines(2)
        elif tag == 'code' and not self.in_pre and self.in_code:
            self.in_code -= 1
            self.parts.append('`')
        elif tag == 'p':
            self.newlines(2)
        elif tag == 'blockquote':
            self.newlines(2)

    def handle_data(self, data):
        if self.skip:
            return
        if self.in_a:
            self.a_text.append(data)
        elif self.in_pre:
            self.parts.append(data)
        else:
            self.parts.append(re.sub(r'\s+', ' ', data))


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 12000
    mark = sys.argv[2] if len(sys.argv) > 2 else ''
    base = sys.argv[3] if len(sys.argv) > 3 else ''
    p = P()
    p.base = base
    p.feed(sys.stdin.read())
    text = ''.join(p.parts)
    text = re.sub(r'[ \t]+\n', '\n', text)
    text = re.sub(r'\n{3,}', '\n\n', text)
    text = re.sub(r'\n(#+)\n', r'\n\1 ', text)   # heading text landed on next line
    text = re.sub(r'^\n*#+\s*$', '', text, flags=re.M)
    text = text.strip()
    if mark:
        i = text.find(mark)
        if i >= 0:
            text = text[i:]
    print(text[:n])
    if len(text) > n:
        print(f'\n[... truncated at {n} chars, total {len(text)}]')


if __name__ == '__main__':
    main()
