"""绘制 OpenNote 自有书页图标；生成的 ICO 随源码保存，构建无需 Pillow。"""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
image = Image.new('RGBA', (512, 512), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((24, 24, 488, 488), radius=108, fill='#397BD0')
draw.polygon([(96, 122), (238, 146), (238, 386), (96, 362)], fill='white')
draw.polygon([(274, 146), (416, 122), (416, 362), (274, 386)], fill='white')
for offset in (0, 65, 130):
    draw.line([(122, 185 + offset), (208, 200 + offset)], fill='#397BD0', width=12)
    draw.line([(304, 200 + offset), (390, 185 + offset)], fill='#397BD0', width=12)
draw.line([(256, 151), (256, 383)], fill='white', width=12)
target = root / 'windows' / 'runner' / 'resources' / 'app_icon.ico'
image.save(target, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print(str(target))
