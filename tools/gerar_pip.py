"""Gera versões QUADRADAS dos GIFs da carinha para a janelinha flutuante (Picture-in-Picture).

Os GIFs normais têm cantos arredondados e transparentes; a janelinha do Android é quadrada,
por isso os cantos apareciam com outra cor. Aqui os cantos são preenchidos, frame a frame,
com a cor do próprio quadrado da carinha (que muda, por exemplo, na cara zangada).
Uso: python3 tools/gerar_pip.py   (lê assets/emojis/, escreve assets/emojis_pip/)
"""
import glob
import os

from PIL import Image

SRC = 'assets/emojis'
DST = 'assets/emojis_pip'
os.makedirs(DST, exist_ok=True)

for path in sorted(glob.glob(f'{SRC}/*.gif')):
    im = Image.open(path)
    frames, durations = [], []
    i = 0
    while True:
        rgba = im.convert('RGBA')
        tile = rgba.getpixel((120, 3))[:3]  # cor do quadrado nesta frame
        bg = Image.new('RGBA', rgba.size, tile + (255,))
        bg.alpha_composite(rgba)
        frames.append(bg.convert('RGB'))
        durations.append(im.info.get('duration', 80))
        i += 1
        try:
            im.seek(i)
        except EOFError:
            break
    out = f'{DST}/{os.path.basename(path)}'
    frames[0].save(out, save_all=True, append_images=frames[1:], duration=durations,
                   loop=0, optimize=True, disposal=1)
    print(f'{os.path.basename(path)}: {len(frames)} frames, {os.path.getsize(out) // 1024} KB')
