"""Compose bilingual App Store artwork using real production UI captures.

python3 tool/store/compose.py [capture-directory] [output-directory]
"""
from pathlib import Path
import json
import sys
import zipfile
import urllib.request
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
CAPTURES = Path(sys.argv[1]) if len(sys.argv)>1 else ROOT/'build/store-captures-v2'
OUTPUT = Path(sys.argv[2]) if len(sys.argv)>2 else ROOT/'store/v2'
CJK = ROOT/'build/store-fonts/NotoSansSC-VF.ttf'
if not CJK.exists():
    CJK.parent.mkdir(parents=True,exist_ok=True)
    urllib.request.urlretrieve('https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/Variable/TTF/Subset/NotoSansSC-VF.ttf',CJK)
SF = '/System/Library/Fonts/SFNS.ttf'
GREEN = '#B7F34C'
COPY = {
    'zh-Hans': [
        ('出门不带电脑','Agent 照样干活','手机发指令，电脑上的 Agent 接着做'),
        ('随时续聊','也能开启新任务','Agent、模型与思考强度，都由你选择'),
        ('剩余额度','一眼有数','查看各 Agent 的可用状态与剩余额度'),
        ('权限由你批准','问题随手回答','关键操作不耽搁，Agent 接着往下做'),
        ('看清每处变更','远程完成提交','查看 Diff、暂存、提交与推送，手机上完成'),
        ('电脑上的命令','手机上执行','随时打开远程终端，查看输出、执行命令'),
        ('电脑运行项目','手机直接预览','启动开发服务，在手机里查看 Web 运行效果'),
        ('需要动手时','直接控制电脑','打开远程桌面，操作屏幕、键鼠与剪贴板'),
    ],
    'en-US': [
        ('Leave the laptop.','Lead your agents.','From your phone, direct agents on your computer.'),
        ('Pick your agent.','Set the pace.','Resume a PC chat or start fresh. Choose model and reasoning.'),
        ('Know what’s left.','Across your agents.','Check agent availability and remaining usage.'),
        ('Approve requests.','Keep work moving.','Grant permissions and answer your agents’ questions.'),
        ('Review the diff.','Commit anywhere.','Stage, commit, and push changes from your phone.'),
        ('Your PC terminal.','In your pocket.','Run commands on your computer, wherever you are.'),
        ('Run it on your PC.','See it on your phone.','Start a dev server, then preview your web app.'),
        ('Take the controls.','From your phone.','Open remote desktop. Use keyboard, mouse, and clipboard.'),
    ],
}
NAMES = ['01-agents-anywhere','02-chat-and-agent-choice','03-agent-quota','04-permissions-and-questions',
         '05-git-commits','06-pc-terminal','07-run-and-web-preview','08-remote-desktop']
SIZES = {
    'iphone-large-1320x2868': (1320,2868,'iphone'),
    'iphone-medium-1206x2622': (1206,2622,'iphone'),
    'ipad-13-2064x2752': (2064,2752,'ipad'),
}

def font(size,latin=False,bold=True):
    result=ImageFont.truetype(SF if latin else str(CJK),round(size))
    if latin: result.set_variation_by_name('Semibold' if bold else 'Regular')
    else: result.set_variation_by_axes([650 if bold else 400])
    return result


def wordmark(draw,x,y,size,color):
    face=font(size,latin=True)
    for text,fill in [('dog',color),('.',GREEN),('codes',color)]:
        draw.text((x,y),text,font=face,fill=fill,anchor='ls')
        x+=draw.textlength(text,font=face)


def background(size,hero):
    width,height=size
    top=(11,15,12) if hero else (247,248,244)
    bottom=(24,36,20) if hero else (225,236,211)
    strip=Image.new('RGB',(1,height))
    strip.putdata([tuple(round(a+(b-a)*max(0,(y/height-.48)/.52)**1.5) for a,b in zip(top,bottom)) for y in range(height)])
    return strip.resize((width,height))


def device(canvas,screenshot,bounds,tablet=False):
    x,y,width,height=map(round,bounds)
    border=round(width*(.012 if tablet else .014))
    radius=round(width*(.047 if tablet else .124))
    shadow=Image.new('RGBA',canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((x,y+22,x+width,y+height+22),radius=radius,fill=(12,24,8,56))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(round(width*.035))))
    draw=ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x,y,x+width,y+height),radius=radius,fill='#232823',outline='#6B7368',width=2)
    inside=(width-2*border,height-2*border)
    assert abs(inside[0]/inside[1]-screenshot.width/screenshot.height)<.002
    shot=screenshot.resize(inside,Image.Resampling.LANCZOS).convert('RGBA')
    mask=Image.new('L',inside)
    ImageDraw.Draw(mask).rounded_rectangle((0,0,inside[0]-1,inside[1]-1),radius=max(1,radius-border),fill=255)
    shot.putalpha(mask)
    canvas.alpha_composite(shot,(x+border,y+border))


def landscape_device(canvas,screenshot,bounds):
    x,y,w,h=map(round,bounds)
    border=round(w*.014);radius=round(h*.12)
    shadow=Image.new('RGBA',canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((x,y+25,x+w,y+h+25),radius=radius,fill=(12,24,8,65))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(round(w*.026))))
    ImageDraw.Draw(canvas).rounded_rectangle((x,y,x+w,y+h),radius=radius,fill='#232823',outline='#6B7368',width=2)
    inside=(w-2*border,h-2*border)
    shot=screenshot.resize(inside,Image.Resampling.LANCZOS).convert('RGBA')
    mask=Image.new('L',inside)
    ImageDraw.Draw(mask).rounded_rectangle((0,0,inside[0]-1,inside[1]-1),radius=radius-border,fill=255)
    shot.putalpha(mask);canvas.alpha_composite(shot,(x+border,y+border))


def wrap(draw,text,face,max_width):
    # Only subtitles wrap. Headlines have intentional editorial line breaks.
    words=text.split(' ') if ' ' in text else list(text)
    joiner=' ' if ' ' in text else ''
    lines=[];line=''
    for word in words:
        candidate=joiner.join([line,word]) if line else word
        if line and draw.textlength(candidate,font=face)>max_width:
            lines.append(line);line=word
        else:line=candidate
    if line:lines.append(line)
    return lines


def poster(language,index,size,source):
    width,height=size;tablet=source=='ipad';unit=width/(2064 if tablet else 1320)
    hero=index==0;latin=language=='en-US'
    color='#F4F6F1' if hero else '#172016'
    secondary='#A7B09F' if hero else '#64705D'
    canvas=background(size,hero).convert('RGBA');draw=ImageDraw.Draw(canvas)
    left=round((140 if tablet else 100)*unit)
    baseline=round((146 if tablet else 128)*unit)
    wordmark(draw,left,baseline,round((56 if tablet else 44)*unit),color)
    draw.text((width-left,baseline),f'{index+1:02} / 08',font=font((28 if tablet else 24)*unit,True,False),fill=secondary,anchor='rs')
    first,second,subtitle=COPY[language][index]
    headline_size=(145 if tablet else 112)*unit
    while max(draw.textlength(line,font=font(headline_size,latin)) for line in [first,second])>width-2*left:
        headline_size-=1
    headline=font(headline_size,latin)
    y=(250 if tablet else 212)*unit;leading=(180 if tablet else 145)*unit
    draw.text((left,round(y)),first,font=headline,fill=color,anchor='lt')
    draw.text((left,round(y+leading)),second,font=headline,fill=GREEN if hero else color,anchor='lt')
    caption_font=font((43 if tablet else 34)*unit,latin,False)
    captions=wrap(draw,subtitle,caption_font,width-2*left)
    assert len(captions)<=2
    caption_top=(651 if tablet else 530)*unit
    for row,text in enumerate(captions):
        draw.text((left,round(caption_top+row*(56 if tablet else 46)*unit)),text,font=caption_font,fill=secondary,anchor='lt')
    name=f'{source}-preview.png' if index==6 else f'{source}-{index+1}.png'
    shot=Image.open(CAPTURES/language/name).convert('RGB')
    if index == 6:
        # Normalize only the OS status strip (9:41, battery, camera cutout).
        # The app and WKWebView content below it remain the native capture.
        status=Image.open(CAPTURES/language/f'{source}-1.png').convert('RGB')
        status_height=177 if source=='iphone' else 56
        shot.paste(status.crop((0,0,status.width,status_height)),(0,0))
    device_width=round((1440 if tablet else 1024)*unit)
    border=round(device_width*(.012 if tablet else .014))
    device_height=round((device_width-2*border)*shot.height/shot.width)+2*border
    top=round((795 if tablet else 635)*unit)
    if top+device_height>height-60*unit:top=round(height-60*unit-device_height)
    assert top>caption_top+len(captions)*(56 if tablet else 46)*unit+10*unit
    if index == 7 and not tablet:
        # Desktop control benefits from the actual landscape layout: larger
        # shared screen and visible input controls, without portrait letterbox.
        shot = Image.open(CAPTURES/language/'iphone-10.png').convert('RGB')
        dw = round(1200*unit)
        border = round(dw*.014)
        dh = round((dw-2*border)*shot.height/shot.width)+2*border
        # Physical corner radius follows the short side in landscape.
        landscape_device(canvas,shot,((width-dw)/2,820*unit,dw,dh))
        labels = [('鼠标与键盘','使用电脑熟悉的快捷键'),('屏幕移动与缩放','按需要调整远程画面'),('双向剪贴板','在手机与电脑间复制文字和图片')] if not latin else [
            ('Mouse & keyboard','Use familiar desktop shortcuts'),
            ('Pan & zoom','Adjust the remote view as you work'),
            ('Two-way clipboard','Move text and images between devices')]
        draw = ImageDraw.Draw(canvas)
        for row,(label,detail) in enumerate(labels):
            sy = round((1690+280*row)*unit)
            draw.line((left,sy-45*unit,width-left,sy-45*unit),fill='#CDD6C5',width=max(1,round(2*unit)))
            draw.text((left,sy),f'0{row+1}',font=font(29*unit,True,False),fill='#7A8D69',anchor='lt')
            draw.text((left+100*unit,sy-10*unit),label,font=font(56*unit,latin),fill=color,anchor='lt')
            draw.text((left+100*unit,sy+78*unit),detail,font=font(33*unit,latin,False),fill=secondary,anchor='lt')
    elif index == 6:
        # Show the PC run controls and actual mobile WebView together. Both
        # preserve their app content; overlap only the device frames.
        back = Image.open(CAPTURES/language/f'{source}-7.png').convert('RGB')
        small_width = round((1200 if tablet else 780)*unit)
        small_border = round(small_width*(.012 if tablet else .014))
        back_height = round((small_width-2*small_border)*back.height/back.width)+2*small_border
        front_height = round((small_width-2*small_border)*shot.height/shot.width)+2*small_border
        back_top = round((820 if tablet else 760)*unit)
        front_top = min(round(back_top+(220 if tablet else 260)*unit),round(height-70*unit-front_height))
        device(canvas,back,(40*unit,back_top,small_width,back_height),tablet)
        device(canvas,shot,(width-small_width-40*unit,front_top,small_width,front_height),tablet)
    else:
        device(canvas,shot,((width-device_width)/2,top,device_width,device_height),tablet)
    if hero:
        footer='Requires a paired, online computer.' if latin else '需连接已配对、在线的电脑'
        ImageDraw.Draw(canvas).text((width/2,height-round(25*unit)),footer,
            font=font((24 if tablet else 20)*unit,latin,False),fill=secondary,anchor='ms')
    return canvas.convert('RGB')


def contact_sheet(directory):
    tw=330;th=round(tw*2868/1320);gap=22
    sheet=Image.new('RGB',(4*tw+5*gap,2*th+3*gap),'#E8ECE3')
    for index,name in enumerate(NAMES):
        shot=Image.open(directory/'iphone-large-1320x2868'/f'{name}.png')
        shot.thumbnail((tw,th),Image.Resampling.LANCZOS)
        sheet.paste(shot,(gap+(index%4)*(tw+gap),gap+(index//4)*(th+gap)))
    sheet.save(directory/'overview.jpg',quality=95,subsampling=0)


OUTPUT.mkdir(parents=True,exist_ok=True)
for language in COPY:
    directory=OUTPUT/language;directory.mkdir(parents=True,exist_ok=True)
    manifest={'language':language,'screenshots':[], 'source':'Production Flutter UI with isolated fictional PC data. Real WKWebView for web preview. Full Chinese and English app localization.'}
    for group,(width,height,source) in SIZES.items():
        folder=directory/group;folder.mkdir(parents=True,exist_ok=True)
        for index,name in enumerate(NAMES):
            path=folder/f'{name}.png';shot=poster(language,index,(width,height),source)
            shot.save(path,optimize=True)
            manifest['screenshots'].append({'file':str(path.relative_to(directory)),'width':width,'height':height,'title':' / '.join(COPY[language][index][:2])})
    contact_sheet(directory)
    (directory/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    (directory/'README.md').write_text(f'''# DogCodes App Store · {language}

8 images in each size. Upload in filename order: agents anywhere, conversation and agent/model/reasoning selection, remaining quota, permissions and questions, Git, PC terminal, run and web preview, remote desktop.

- iphone-large-1320x2868: large iPhone
- iphone-medium-1206x2622: medium iPhone
- ipad-13-2064x2752: 13-inch iPad
- overview.jpg is a review contact sheet; do not upload it as a screenshot.

All upload files are opaque RGB PNGs. Dimensions follow Apple’s screenshot specifications:
https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/

Screens use the production Flutter widgets and the app’s actual localization. Conversations, code, commands, quotas, and the Canvas demo project are fictional. No personal content or real account is used. No PC commands or Git operations are executed during capture. The preview uses the real iOS WKWebView through PreviewPage and its normal proxy. Remote desktop renders a desktop-sized capture of the demo website with the real remote desktop widget; the authoring harness uses its image transport mode. OS status bars are normalized to 9:41 and full battery. The app requires an authorized, paired, online computer and agents configured there.

The English app follows system language preferences; Simplified Chinese is also supported. These are actual localized UI captures, not translated overlays.
''')
    archive=OUTPUT/f'dogcodes-app-store-{language}.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        for path in sorted(directory.rglob('*')):
            if path.is_file():z.write(path,str(path.relative_to(OUTPUT)))
    print(f'Exported {language}: 24 PNGs, overview, archive.',flush=True)

(OUTPUT/'README.md').write_text('''# DogCodes bilingual App Store screenshots

48 upload PNGs: 8 features × 2 languages × 3 device sizes. Each language has an upload archive and contact sheet.

Rebuild on macOS with Flutter, Chrome, Xcode simulators and Pillow:

```sh
python3 tool/l10n/generate.py
python3 tool/store/capture_desktop.py
STORE_CAPTURE_DIR="$PWD/build/store-captures-v2" flutter test tool/store/capture.dart
python3 tool/store/capture_preview.py
python3 tool/store/compose.py
```

The desktop capture script renders tool/store/canvas.html in an isolated Chrome profile at 1600×1000. The preview script creates and removes isolated simulators, and does not use existing device data. Poster titles live in tool/store/compose.py. UI messages live in lib/l10n/en.json; regenerate catalog.dart after editing.
''')
archive=OUTPUT.parent/'dogcodes-app-store-bilingual-v2.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
    z.write(OUTPUT/'README.md','README.md')
    for language in COPY:
        for path in sorted((OUTPUT/language).rglob('*')):
            if path.is_file():z.write(path,str(path.relative_to(OUTPUT)))
assert all(zipfile.ZipFile(p).testzip() is None for p in [archive,*OUTPUT.glob('*.zip')])
print(f'Bilingual upload archive: {archive}')
