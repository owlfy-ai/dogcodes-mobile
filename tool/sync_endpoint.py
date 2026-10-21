#!/usr/bin/env python3
"""Copy the versioned endpoint source snapshot; no cross-repository build dependency."""
import argparse,hashlib,json,shutil
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=root.parent/'DogCodes/crates/remote-endpoint');p.add_argument('--check',action='store_true');args=p.parse_args()
files=['Cargo.toml','src/lib.rs','src/ffi.rs','src/pairing.rs','tests/security.rs','tests/vectors.rs','tests/fixtures/noise-vectors.json']
for name in files:
 src=args.source/name;dst=root/'native/endpoint'/name
 if args.check:
  if src.read_bytes()!=dst.read_bytes():raise SystemExit(f'Endpoint snapshot differs: {name}')
 else:
  dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
if not args.check:
 (root/'native/endpoint/source.json').write_text(json.dumps({'source':'DogCodes/crates/remote-endpoint','version':'0.1.0','files':{n:hashlib.sha256((args.source/n).read_bytes()).hexdigest() for n in files}},indent=2)+'\n')
