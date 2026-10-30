"""Render the fictional web project in Chrome, without using personal tabs."""
from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
from PIL import Image

root=Path(__file__).resolve().parents[2]
output=root/'build/store-captures-v2/desktop.png'
output.parent.mkdir(parents=True,exist_ok=True)
with TemporaryDirectory(prefix='dogcodes-store-chrome-') as profile:
    subprocess.run([
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '--headless',f'--user-data-dir={profile}','--disable-gpu',
        '--hide-scrollbars','--no-proxy-server',f'--screenshot={output}',
        '--window-size=1600,1000','--force-device-scale-factor=1',
        (root/'tool/store/canvas.html').as_uri(),
    ],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=45)
assert Image.open(output).size==(1600,1000)
print(output)
