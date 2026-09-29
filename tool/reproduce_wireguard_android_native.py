#!/usr/bin/env python3
"""Rebuild all four retained libwg-go ELFs and compare packaged bytes."""
from __future__ import annotations
import argparse, hashlib, json, os, re, shutil, subprocess, tarfile, urllib.request, zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'third_party/wireguard-android/wireguard-android-1.0.20260102-source.tar.gz'
AAR=ROOT/'third_party/maven/ai/zagros/thirdparty/wireguard-tunnel-go-only/1.0.20260102/wireguard-tunnel-go-only-1.0.20260102.aar'
MANIFEST=ROOT/'third_party/wireguard-android/embedded-native-sha256.json'
TEMPLATE=ROOT/'tool/wireguard_go_only_CMakeLists.txt'
REPORT=ROOT/'third_party/wireguard-go/native-reproduction.json'
NDK_URL='https://dl.google.com/android/repository/android-ndk-r27-linux.zip'
NDK_SIZE=663_957_918
NDK_SHA='2f17eb8bcbfdc40201c0b36e9a70826fcd2524ab7a2a235e2c71186c302da1dc'
GO_SHA='3333f6ea53afa971e9078895eaa4ac7204a8c6b5c68c10e6bc9a33e8e391bdd8'
ABIS=('arm64-v8a','armeabi-v7a','x86','x86_64')
CMAKE_WHEEL={'version':'4.4.3','size':30231983,'sha256':'bae3c4954623ec4d62e62c70443f0da7988b733111c2871fcc6a31ead5137e20'}
NINJA_WHEEL={'version':'1.13.2','size':183365,'sha256':'65a24341b5ac09fcadcc37082660be40a94174e51a937fabf6e2cae26225fa2c'}

def sha(path:Path)->str:
 h=hashlib.sha256()
 with path.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
 return h.hexdigest()

def run(command:list[str],**kwargs)->subprocess.CompletedProcess:
 return subprocess.run(command,check=True,text=True,**kwargs)

def verify_template()->None:
 with tarfile.open(ARCHIVE,'r:gz') as archive:
  stream=archive.extractfile('wireguard-android-1.0.20260102/tunnel/tools/CMakeLists.txt')
  if stream is None: raise SystemExit('upstream CMakeLists missing')
  upstream=stream.read().decode()
 template=TEMPLATE.read_text()
 required=[
  'set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")',
  'add_link_options(LINKER:--build-id=none)','add_compile_options(-Wall -Werror)',
  'add_custom_target(libwg-go.so WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/libwg-go"',
  'ANDROID_ARCH_NAME=${ANDROID_ARCH_NAME}','ANDROID_PACKAGE_NAME=${ANDROID_PACKAGE_NAME}',
  'GRADLE_USER_HOME=${GRADLE_USER_HOME}','CC=${CMAKE_C_COMPILER}',
  'CFLAGS=${CMAKE_C_FLAGS}','LDFLAGS=${CMAKE_SHARED_LINKER_FLAGS}',
  'SYSROOT=${CMAKE_SYSROOT}','TARGET=${CMAKE_C_COMPILER_TARGET}',
  'DESTDIR=${CMAKE_LIBRARY_OUTPUT_DIRECTORY}',
  'BUILDDIR=${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/../generated-src']
 for text in required:
  if text not in upstream or text not in template: raise SystemExit(f'reproduction template drift: {text}')
 code='\n'.join(line for line in template.splitlines() if not line.lstrip().startswith('#'))
 for forbidden in ('wireguard-tools','libwg-quick.so','add_executable(libwg.so'):
  if forbidden in code: raise SystemExit(f'reproduction template includes forbidden target: {forbidden}')

def ensure_ndk(work:Path)->Path:
 ndk=work/'android-ndk-r27'
 if ndk.is_dir(): return ndk
 package=work/'android-ndk-r27-linux.zip'
 with urllib.request.urlopen(NDK_URL,timeout=300) as response,package.open('wb') as out:
  while block:=response.read(1024*1024): out.write(block)
 if package.stat().st_size!=NDK_SIZE or sha(package)!=NDK_SHA: raise SystemExit('NDK archive mismatch')
 with zipfile.ZipFile(package) as archive: archive.extractall(work)
 package.unlink()
 return ndk

def main()->int:
 parser=argparse.ArgumentParser(); parser.add_argument('--work',required=True,type=Path); parser.add_argument('--cmake',required=True,type=Path); parser.add_argument('--ninja',required=True,type=Path); args=parser.parse_args()
 verify_template(); args.work.mkdir(parents=True,exist_ok=True)
 env=os.environ.copy(); tool_root=args.cmake.parent.parent
 if (tool_root/'cmake').is_dir(): env['PYTHONPATH']=str(tool_root)+os.pathsep+env.get('PYTHONPATH','')
 env['PATH']=str(args.ninja.parent)+os.pathsep+env.get('PATH','')
 cmake_version=run([str(args.cmake),'--version'],env=env,capture_output=True).stdout
 ninja_version=run([str(args.ninja),'--version'],env=env,capture_output=True).stdout.strip()
 if 'cmake version 4.4.3' not in cmake_version or not ninja_version.startswith('1.13.2'): raise SystemExit('reproduction requires locked CMake 4.4.3 and Ninja 1.13.2')
 ndk=ensure_ndk(args.work); source_root=args.work/'wireguard-android-1.0.20260102'
 if source_root.exists(): shutil.rmtree(source_root)
 with tarfile.open(ARCHIVE,'r:gz') as archive: archive.extractall(args.work,filter='data')
 minimal=args.work/'go-only-tools'
 if minimal.exists(): shutil.rmtree(minimal)
 minimal.mkdir(); shutil.copyfile(TEMPLATE,minimal/'CMakeLists.txt')
 (minimal/'libwg-go').symlink_to(source_root/'tunnel/tools/libwg-go',target_is_directory=True)
 expected=json.loads(MANIFEST.read_text())['files']; outputs=[]
 env['GOPATH']=str(args.work/'gopath'); env['GOMODCACHE']=str(args.work/'gomodcache'); env['GOCACHE']=str(args.work/'gocache')
 for abi in ABIS:
  build=args.work/f'cmake-{abi}'
  if build.exists(): shutil.rmtree(build)
  run([str(args.cmake),'-S',str(minimal),'-B',str(build),'-G','Ninja','-DCMAKE_POLICY_VERSION_MINIMUM=3.5',f'-DCMAKE_MAKE_PROGRAM={args.ninja}',f'-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake',f'-DANDROID_ABI={abi}','-DANDROID_PLATFORM=android-24','-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON','-DANDROID_PACKAGE_NAME=com.wireguard.android',f'-DGRADLE_USER_HOME={args.work}/gradle-home','-DCMAKE_BUILD_TYPE=Release',f'-DCMAKE_LIBRARY_OUTPUT_DIRECTORY={build}/out'],env=env,capture_output=True)
  run([str(args.cmake),'--build',str(build),'--target','libwg-go.so','--','-j1'],env=env,capture_output=True)
  output=build/'out/libwg-go.so'; strip=ndk/'toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip'
  run([str(strip),'--strip-unneeded',str(output)],env=env,capture_output=True)
  key=f'jni/{abi}/libwg-go.so'; details={'size':output.stat().st_size,'sha256':sha(output)}
  if details!=expected[key]: raise SystemExit(f'{abi}: rebuilt ELF differs: {details}')
  with zipfile.ZipFile(AAR) as archive:
   if output.read_bytes()!=archive.read(key): raise SystemExit(f'{abi}: byte comparison failed')
  ninja_text=(build/'build.ninja').read_text(); command=next(line for line in ninja_text.splitlines() if 'ANDROID_ARCH_NAME=' in line)
  targets=re.findall(r'(?:ANDROID_ARCH_NAME|TARGET)=[^ ]+',command)
  outputs.append({'abi':abi,**details,'byte_identical_to_packaged_aar':True,'generated_target_identity':targets})
 arm64_go=args.work/'cmake-arm64-v8a/generated-src/go-1.24.3/bin/go'
 report={'schema_version':1,'source_archive_sha256':'0d12c37fabf73fe88983e779c077aaad55ff62ea5749bad89ec1a27c60d7ade3','go_toolchain_sha256':GO_SHA,'android_ndk':{'version':'27.0.12077973','archive_size':NDK_SIZE,'archive_sha256':NDK_SHA},'host_build_tools':{'cmake_linux_x86_64_wheel':CMAKE_WHEEL,'ninja_linux_x86_64_wheel':NINJA_WHEEL},'template':str(TEMPLATE.relative_to(ROOT)),'template_sha256':sha(TEMPLATE),'strip':'NDK llvm-strip --strip-unneeded','outputs':outputs,'patched_go_for_reachability':str(arm64_go.relative_to(args.work)),'reproduction_status':'PASS: all four rebuilt and stripped libwg-go ELFs are byte-for-byte identical to the packaged upstream-derived AAR members.','distribution_status':'BLOCKED: native reproduction does not replace final APK/AAB, signing, device tunnel, routed traffic, accounting, or teardown evidence.'}
 REPORT.write_text(json.dumps(report,indent=2)+'\n')
 print(report['reproduction_status']); return 0
if __name__=='__main__': raise SystemExit(main())
