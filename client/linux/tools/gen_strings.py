#!/usr/bin/env python3
"""Строки RU/EN из Android strings.xml → app/i18n/{en,ru}.json (ключи те же).
Плейсхолдеры Android (%1$s, %d, %s) → Qt (%1, %2…). Запуск из корня репозитория:
    python3 client/linux/tools/gen_strings.py
"""
import json, re, sys, xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[3]
src = root / 'client/android/client-kotlin/app/src/main/res'
dst = root / 'client/linux/app/i18n'

def convert(text):
    text = text.replace("\\'", "'").replace('\\"', '"').replace('\\n', '\n').replace('\\@', '@').replace('\\?', '?')
    n = [0]
    def repl(m):
        if m.group(1):
            return '%' + m.group(1)
        n[0] += 1
        return '%' + str(n[0])
    text = re.sub(r'%(?:(\d+)\$)?[sdf]', repl, text)
    return text.replace('%%', '%')

for lang, folder in (('en', 'values'), ('ru', 'values-ru')):
    tree = ET.parse(src / folder / 'strings.xml')
    out = {}
    for el in tree.getroot():
        if el.tag == 'string':
            out[el.get('name')] = convert(''.join(el.itertext()))
        elif el.tag == 'plurals':
            for item in el:
                out[f"{el.get('name')}#{item.get('quantity')}"] = convert(''.join(item.itertext()))
    dst.mkdir(parents=True, exist_ok=True)
    (dst / f'{lang}.json').write_text(json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True), encoding='utf-8')
    print(lang, len(out))
