#!/usr/bin/env python3
"""Generate/verify Android-tagged reachable Go package evidence."""
from __future__ import annotations
import argparse, hashlib, json, os, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'third_party/wireguard-go/android-reachable-packages.json'
MODULE_LOCK=ROOT/'third_party/wireguard-go/module-lock.json'
SOURCE_LOCK=ROOT/'third_party/wireguard-go/source-license-lock.json'
ABIS={
 'arm64-v8a':('arm64','aarch64-none-linux-android24'),
 'armeabi-v7a':('arm','armv7-none-linux-androideabi24'),
 'x86':('386','i686-none-linux-android24'),
 'x86_64':('amd64','x86_64-none-linux-android24'),
}
REACHABLE=['golang.org/x/crypto','golang.org/x/net','golang.org/x/sys','golang.zx2c4.com/wireguard']

def parse_stream(content:str)->list[dict]:
 decoder=json.JSONDecoder(); result=[]; index=0
 while index<len(content):
  while index<len(content) and content[index].isspace(): index+=1
  if index==len(content): break
  item,index=decoder.raw_decode(content,index); result.append(item)
 return result

def generate(go:Path,ndk:Path,source:Path)->None:
 module_items=json.loads(MODULE_LOCK.read_text())['modules']
 locked={item['module']:item for item in module_items}
 source_items=json.loads(SOURCE_LOCK.read_text())['modules']
 licenses={item['module']:[x['path'] for x in item['license_notice_files']] for item in source_items}
 toolchain=ndk/'toolchains/llvm/prebuilt/linux-x86_64'
 sysroot=toolchain/'sysroot'; clang=toolchain/'bin/clang'
 by_package={}
 with tempfile.TemporaryDirectory(prefix='zagros-go-list-',dir=ROOT.parent) as directory:
  cache=Path(directory)
  for abi,(goarch,target) in ABIS.items():
   env=os.environ.copy(); env.update({
    'GOOS':'android','GOARCH':goarch,'CGO_ENABLED':'1','CC':str(clang),
    'CGO_CFLAGS':f'--target={target} --sysroot={sysroot}',
    'CGO_LDFLAGS':f'--target={target} --sysroot={sysroot} -Wl,-soname=libwg-go.so',
    'GOCACHE':str(cache/'build'),'GOMODCACHE':str(cache/'modules'),'GOPATH':str(cache/'gopath')})
   run=subprocess.run([str(go),'list','-deps','-tags','linux','-json','.'],cwd=source,env=env,check=True,capture_output=True,text=True)
   for package in parse_stream(run.stdout):
    path=package['ImportPath']; record=by_package.setdefault(path,{'import_path':path,'standard':bool(package.get('Standard',False)),'module':None,'abis':[]})
    record['abis'].append(abi)
    module=package.get('Module')
    if module:
     name=module['Path']
     if module.get('Main'):
      record['module']={'path':name,'main':True}
     else:
      if name not in locked: raise SystemExit(f'reachable unpinned module: {name}')
      expected=locked[name]
      if module.get('Version')!=expected['version'] or module.get('Sum')!=expected['go_sum']: raise SystemExit(f'module version/sum mismatch: {name}')
      record['module']={'path':name,'version':module['Version'],'sum':module['Sum'],'main':False}
 for item in by_package.values(): item['abis'].sort()
 packages=sorted(by_package.values(),key=lambda x:x['import_path'])
 reachable=sorted({x['module']['path'] for x in packages if x['module'] and not x['module'].get('main')})
 if reachable!=REACHABLE: raise SystemExit(f'unexpected reachable modules: {reachable}')
 report={
  'schema_version':1,'command':'go list -deps -tags linux -json .','go_version':'go1.24.3 with locked Android runtime patch','target':'android API 24','abis':sorted(ABIS),'packages':packages,
  'reachable_modules':[{'module':name,'version':locked[name]['version'],'go_sum':locked[name]['go_sum'],'license_notice_paths':licenses[name]} for name in reachable],
  'unreachable_locked_modules':sorted(set(locked)-set(reachable)),
  'analysis_status':'PASS: all four Android ABI/tag package graphs were generated with the pinned patched Go toolchain; every reachable external module matches the locked version, h1 sum, and captured notice evidence.',
  'distribution_status':'BLOCKED: package reachability does not replace reproducible binary, final APK/AAB, signing, or routed-traffic acceptance.'}
 OUTPUT.write_text(json.dumps(report,indent=2)+'\n')

def verify_local()->None:
 report=json.loads(OUTPUT.read_text())
 if report.get('abis')!=sorted(ABIS) or not report.get('analysis_status','').startswith('PASS:') or not report.get('distribution_status','').startswith('BLOCKED:') or [x['module'] for x in report.get('reachable_modules',[])]!=REACHABLE: raise SystemExit('Android Go reachability report metadata mismatch')
 locked={x['module']:x for x in json.loads(MODULE_LOCK.read_text())['modules']}
 source={x['module']:{y['path'] for y in x['license_notice_files']} for x in json.loads(SOURCE_LOCK.read_text())['modules']}
 for module in report['reachable_modules']:
  expected=locked[module['module']]
  if module['version']!=expected['version'] or module['go_sum']!=expected['go_sum'] or set(module['license_notice_paths'])!=source[module['module']]: raise SystemExit(f"reachable module evidence mismatch: {module['module']}")
 if not report['packages'] or any(not x['abis'] or not set(x['abis']).issubset(ABIS) for x in report['packages']): raise SystemExit('reachable package ABI evidence is malformed')
 print('Android Go reachability report SHA-256:',hashlib.sha256(OUTPUT.read_bytes()).hexdigest())

def main()->int:
 parser=argparse.ArgumentParser(); parser.add_argument('--go',type=Path); parser.add_argument('--ndk',type=Path); parser.add_argument('--source',type=Path); parser.add_argument('--verify-local',action='store_true'); args=parser.parse_args()
 if not args.verify_local:
  if not all((args.go,args.ndk,args.source)): parser.error('--go, --ndk, and --source are required')
  generate(args.go,args.ndk,args.source)
 verify_local(); return 0
if __name__=='__main__': raise SystemExit(main())
