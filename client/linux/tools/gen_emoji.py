#!/usr/bin/env python3
"""Набор эмодзи из Android (ui/emoji/EmojiData.kt) → app/emoji.json — те же категории и порядок.
Запуск из корня репозитория: python3 client/linux/tools/gen_emoji.py
"""
import json, re
from pathlib import Path

root = Path(__file__).resolve().parents[3]
src = root / 'client/android/client-kotlin/app/src/main/kotlin/com/oshinobu/app/ui/emoji/EmojiData.kt'
out = []
for m in re.finditer(r'\w+\(R\.string\.(emoji_\w+), listOf\((.*?)\)\)', src.read_text(encoding='utf-8')):
    out.append({'title': m.group(1), 'emojis': re.findall(r'"([^"]+)"', m.group(2))})
dst = root / 'client/linux/app/emoji.json'
dst.write_text(json.dumps(out, ensure_ascii=False), encoding='utf-8')
print([(c['title'], len(c['emojis'])) for c in out])
