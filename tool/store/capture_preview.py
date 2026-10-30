"""Capture the real iOS WebView in disposable, empty iPhone/iPad simulators."""
from pathlib import Path
import base64
import json
import subprocess
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'build/store-captures-v2'
OUTPUT.mkdir(parents=True, exist_ok=True)
packages = json.loads((ROOT / '.dart_tool/package_config.json').read_text())['packages']
from urllib.parse import urlparse, unquote
flutter = Path(unquote(urlparse(next(p['rootUri'] for p in packages if p['name'] == 'flutter')).path)).parent.parent
defines = ROOT / 'build/store-preview-defines.json'
defines.write_text(json.dumps({'STORE_PREVIEW_HTML_BASE64':base64.b64encode((ROOT/'tool/store/canvas.html').read_bytes()).decode()}))
with (OUTPUT/'preview-build.log').open('w') as log:
    subprocess.run([str(flutter/'bin/flutter'),'build','ios','--simulator','--debug',
        '--target','tool/store/preview_app.dart',f'--dart-define-from-file={defines}'],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)

def sim(*args, **options):
    return subprocess.run(['xcrun','simctl',*args],capture_output=True,text=True,check=True,**options).stdout.strip()

runtime = next(r['identifier'] for r in json.loads(sim('list','runtimes','-j'))['runtimes'] if r['isAvailable'] and r['name'].startswith('iOS 27'))
for language in ['zh-Hans','en-US']:
 for name,kind in [('iphone','com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max'),
                  ('ipad','com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB')]:
     device = sim('create',f'DogCodes Store {name} QA',kind,runtime)
     print('Created isolated preview simulator:',name,flush=True)
     try:
         sim('boot',device)
         sim('bootstatus',device,'-b',timeout=60)
         sim('ui',device,'appearance','light')
         sim('status_bar',device,'override','--time','9:41','--dataNetwork','wifi','--wifiMode','active','--wifiBars','3',
             '--cellularMode','active','--cellularBars','4','--batteryState','charged','--batteryLevel','100')
         sim('install',device,str(ROOT/'build/ios/iphonesimulator/Runner.app'))
         sim('launch',device,'codes.dog.mobile','-AppleLanguages',f'({language})','-AppleLocale',language.replace('-','_'))
         (OUTPUT/language).mkdir(exist_ok=True)
         path=OUTPUT/language/f'{name}-preview.png'
         for attempt in range(8):
             time.sleep(1)
             sim('io',device,'screenshot',str(path))
             image=Image.open(path).convert('RGB')
             tint=sum(1 for r,g,b in image.resize((300,600)).get_flattened_data() if 180<r<245 and g>r+2 and r>b+5)
             if tint>600:
                 print('Real WebView rendered:',language,name,image.size,flush=True)
                 break
         else:
             raise RuntimeError(f'{name}: preview webpage did not render, see {path}')
     finally:
         subprocess.run(['xcrun','simctl','shutdown',device],capture_output=True)
         subprocess.run(['xcrun','simctl','delete',device],capture_output=True)
         print('Removed isolated preview simulator:',name,flush=True)
