#!/usr/bin/env python3
"""Original 秒新 humidifier icon; Pillow only, reproducible opaque RGB assets."""
from pathlib import Path
import json
from PIL import Image, ImageDraw, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parents[1]
SCALE = 2
N = 1024

def curve(start, segments):
    points = [start]
    x, y = start
    for x1, y1, x2, y2, x3, y3 in segments:
        for i in range(1, 49):
            t = i / 48
            u = 1-t
            points.append((u*u*u*x+3*u*u*t*x1+3*u*t*t*x2+t*t*t*x3,
                           u*u*u*y+3*u*u*t*y1+3*u*t*t*y2+t*t*t*y3))
        x, y = x3, y3
    return [(round(a*SCALE), round(b*SCALE)) for a,b in points]


def master():
    size = N*SCALE
    vertical = Image.linear_gradient('L').resize((size,size))
    horizontal = Image.linear_gradient('L').rotate(90).resize((size,size))
    ramp = Image.blend(vertical, horizontal, .5)
    bg = ImageOps.colorize(ramp, '#073E83', '#29D3C9').convert('RGB')
    glow = ImageOps.invert(Image.radial_gradient('L')).resize((size,size))
    glow = Image.eval(glow, lambda v: int(v * .13))
    bg = Image.composite(Image.new('RGB',(size,size),'#9FFFE9'), bg, glow)
    drop = curve((512,206), [(477,275,312,448,312,569),
                             (312,702,395,798,512,798),
                             (629,798,712,702,712,569),
                             (712,448,547,275,512,206)])
    mask = Image.new('L',(size,size)); draw = ImageDraw.Draw(mask)
    draw.polygon(drop,fill=255)
    # Negative-space water currents express humidity and flowing air.
    for start, parts, width in [
        ((371,590),[(419,551,465,562,512,590),(558,617,608,620,654,585)],25),
        ((399,666),[(439,639,477,642,516,663),(553,683,590,682,625,660)],19)]:
        points = curve(start,parts)
        draw.line(points,fill=0,width=width*SCALE,joint='curve')
        r=width*SCALE/2
        for x,y in [points[0],points[-1]]:
            draw.ellipse((x-r,y-r,x+r,y+r),fill=0)
    shadow = Image.new('L',(size,size))
    shadow.paste(mask,(0,20*SCALE))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22*SCALE))
    shadow = Image.eval(shadow,lambda v:int(v*.19))
    bg = Image.composite(Image.new('RGB',(size,size),'#032E67'),bg,shadow)
    white = ImageOps.colorize(Image.linear_gradient('L').resize((size,size)), '#FFFFFF','#DEFFF8')
    bg = Image.composite(white,bg,mask)
    return bg.resize((N,N),Image.Resampling.LANCZOS).convert('RGB')


def main():
    image = master()
    assets=ROOT/'Assets.xcassets'
    icons=assets/'AppIcon.appiconset'
    icons.mkdir(parents=True,exist_ok=True)
    (assets/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}},indent=2)+'\n')
    specs=[('iphone',20,[2,3]),('iphone',29,[2,3]),('iphone',40,[2,3]),('iphone',60,[2,3]),
           ('ipad',20,[1,2]),('ipad',29,[1,2]),('ipad',40,[1,2]),('ipad',76,[1,2]),('ipad',83.5,[2]),
           ('ios-marketing',1024,[1])]
    entries=[]
    for idiom,pt,scales in specs:
        for scale in scales:
            size=int(pt*scale)
            filename=f'Icon-{size}.png'
            image.resize((size,size),Image.Resampling.LANCZOS).save(icons/filename,optimize=True)
            entries.append({'idiom':idiom,'size':f'{pt:g}x{pt:g}','scale':f'{scale}x','filename':filename})
    (icons/'Contents.json').write_text(json.dumps({'images':entries,'info':{'author':'xcode','version':1}},indent=2)+'\n')
    preview=Path('/var/minis/attachments/MiaoxinHumidifier-AppIcon.png')
    image.save(preview,optimize=True)
    print(f'Generated {len(entries)} AppIcon entries; master: {preview}')

if __name__=='__main__': main()
