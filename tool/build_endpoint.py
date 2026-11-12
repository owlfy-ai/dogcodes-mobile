#!/usr/bin/env python3
"""Build bundled endpoint libraries. Does not install SDKs or accept licenses."""
import argparse,os,platform,subprocess,shutil
from pathlib import Path
root=Path(__file__).resolve().parents[1]
os.environ['PATH']=str(Path.home()/'.cargo/bin')+os.pathsep+os.environ.get('PATH','')
p=argparse.ArgumentParser();p.add_argument('platform',choices=['android','ios','host']);p.add_argument('--release',action='store_true')
# Android keeps one library per build type, so a debug build never ships in a release.
p.add_argument('--variant',default='debug',choices=['debug','profile','release']);args=p.parse_args()
# Xcode names the configuration; Release and Profile builds must not link the debug library.
if args.platform=='ios' and os.environ.get('CONFIGURATION','').split('-')[0] in ('Release','Profile'):args.release=True
if args.platform=='android' and args.variant in ('profile','release'):args.release=True
manifest=root/'native/endpoint/Cargo.toml';profile='release' if args.release else 'debug'
def build(target,extra=None):
 cmd=['cargo','build','--locked','--manifest-path',str(manifest),'--target',target]
 if args.release:cmd+=['--release']
 subprocess.run(cmd,check=True,env=dict(os.environ,**(extra or {})))
 return root/'native/endpoint/target'/target/profile
if args.platform=='android':
 sdk=Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or str(Path.home()/'Library/Android/sdk'))
 ndk=sdk/'ndk/28.2.13676358'
 if not ndk.is_dir():raise SystemExit('Install Android NDK 28.2.13676358 in Android Studio SDK Manager first.')
 host='darwin-x86_64' if platform.system()=='Darwin' else 'linux-x86_64'
 tools=ndk/'toolchains/llvm/prebuilt'/host/'bin'
 # ARM64 is the first supported mobile ABI; other ABIs fail explicitly.
 target='aarch64-linux-android';cc=tools/'aarch64-linux-android24-clang'
 dest=root/'android/app/src'/args.variant/'jniLibs/arm64-v8a';dest.mkdir(parents=True,exist_ok=True)
 # Earlier builds kept one shared copy; it would merge with this build type's own.
 stale=root/'android/app/src/main/jniLibs/arm64-v8a/libdogcodes_endpoint.so'
 if stale.exists():stale.unlink()
 out=build(target,{'CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER':str(cc),'CC_aarch64_linux_android':str(cc),'AR_aarch64_linux_android':str(tools/'llvm-ar')})
 shutil.copy2(out/'libdogcodes_endpoint.so',dest/'libdogcodes_endpoint.so')
elif args.platform=='ios':
 target=('x86_64-apple-ios' if os.environ.get('ARCHS')=='x86_64' else 'aarch64-apple-ios-sim') if os.environ.get('PLATFORM_NAME','iphonesimulator')=='iphonesimulator' else 'aarch64-apple-ios'
 out=build(target)
 dest=root/'ios/Endpoint';dest.mkdir(parents=True,exist_ok=True)
 shutil.copy2(out/'libdogcodes_endpoint.a',dest/'libdogcodes_endpoint.a')
else:
 subprocess.run(['cargo','build','--locked','--manifest-path',str(manifest)],check=True)
