#!/usr/bin/env python3
"""Public synthetic restore archive; optional locked-source identity oracle."""
import argparse,ast,base64,hashlib,io,json,logging,plistlib,tarfile,zipfile
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'Tests/OmarchyAppleInstallerTrustCoreTests/Fixtures/native-stub-files.json'
def vectors():
    info=dict(BuildNumber='25G83',DeviceClass='j700ap',RestoreBehavior='Erase',Variant='macOS Customer')
    identity=dict(ApBoardID='0x01',ApChipID='0x0002',Info=info,Manifest={
        'BaseSystem':dict(Info=dict(Path='recovery.dmg')),
        'KernelCache':dict(Info=dict(Path='kernelcache.fixture')),
        'CryptexSystemVolume':dict(Info=dict(Path='excluded.img'))})
    document=dict(BuildIdentities=[dict(identity,ApBoardID='0x02'),identity])
    version=dict(ProductVersion='26.6.2',ProductUserVisibleVersion='26.6.2',ProductBuildVersion='25G83')
    recovery=b'i'*(131072+13)+b'koly'+bytes(508)
    files={'BuildManifest.plist':plistlib.dumps(document),'SystemVersion.plist':plistlib.dumps(version),
      'RestoreVersion.plist':plistlib.dumps(dict(RestoreLongVersion='25G83')),
      'PlatformSupport.plist':plistlib.dumps(dict(SupportedModelProperties=[])),
      'BootabilityBundle/Restore/Bootability/manifest.im4m':b'bootability',
      'BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache':b'trust-cache',
      'Firmware/Manifests/restore/macOS Customer/demo.im4m':b'restore-manifest',
      'kernelcache.fixture':b'synthetic kernel component','excluded.img':b'excluded',
      'recovery.dmg':recovery}
    result=[]
    for path in (None,'./Restore','../Escape','AEA','links','escape-link','cycle-link','dangling-link','bad-member'):
        current=dict(files)
        if path=='AEA':current['recovery.dmg']=b'AEA1synthetic encrypted input'
        current['usr/standalone/bootcaches.plist']=plistlib.dumps(dict(bless2={} if path not in ('./Restore','../Escape') else dict(RestoreBundlePath=path)))
        links={}
        if path in ('links','escape-link','cycle-link','dangling-link'):
            prefix='BootabilityBundle/Restore/Bootability/Demo.framework/'
            current[prefix+'Versions/A/Demo']=b'synthetic framework executable'
            current[prefix+'Versions/A/Resources/Info.plist']=b'synthetic resource'
            links={prefix+'Demo':b'Versions/Current/Demo',prefix+'Resources':b'Versions/Current/Resources',prefix+'Versions/Current':b'A'}
            if path=='escape-link':links[prefix+'Versions/Current']=b'../../../../Escape'
            if path=='cycle-link':links[prefix+'Versions/Current']=b'Current'
            if path=='dangling-link':links[prefix+'Versions/Current']=b'Missing'
            current.update(links)
        output=io.BytesIO()
        with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_STORED) as z:
            for name,data in sorted(current.items()):
                member=zipfile.ZipInfo(name,(2020,1,1,0,0,0));member.compress_type=zipfile.ZIP_STORED;member.external_attr=(0o120755 if name in links else 0o100644)<<16;z.writestr(member,data)
        encoded=output.getvalue()
        if path=='bad-member':
            encoded=bytearray(encoded)
            name=b'PlatformSupport.plist';position=encoded.index(name)-30
            encoded[position+8:position+10]=(99).to_bytes(2,'little')
            encoded=bytes(encoded)
        result.append(dict(name='fallback' if path is None else 'explicit' if path=='./Restore' else 'aea' if path=='AEA' else 'unsafe' if path=='../Escape' else path,
          archive=base64.b64encode(encoded).decode(),success=path not in ('../Escape','escape-link','cycle-link','dangling-link','bad-member')))
    return dict(vectors=result,expectedManifest=base64.b64encode(plistlib.dumps(dict(BuildIdentities=[identity]))).decode(),
      expectedVersion=dict(version,ProductUserVisibleVersion=version['ProductUserVisibleVersion']+' (stub)'),
      recoveryBytes=len(recovery),recoverySHA256=hashlib.sha256(recovery).hexdigest())
def main():
    p=argparse.ArgumentParser();p.add_argument('--write',action='store_true');p.add_argument('--runtime',type=Path);a=p.parse_args();value=vectors()
    if a.runtime:
        with tarfile.open(a.runtime) as archive:
            member=next(x for x in archive.getmembers() if x.name.removeprefix('./')=='stub.py');source=archive.extractfile(member).read()
        tree=ast.parse(source);cls=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='StubInstaller')
        method=next(n for n in cls.body if isinstance(n,ast.FunctionDef) and n.name=='load_identity')
        scope=dict(plistlib=plistlib,logging=logging)
        exec(compile(ast.Module(body=[method],type_ignores=[]),'locked-stub-identity','exec'),scope)
        for record in value['vectors']:
            with zipfile.ZipFile(io.BytesIO(base64.b64decode(record['archive']))) as archive:
                fake=SimpleNamespace(get_paths=lambda:None,open=lambda name:io.BytesIO(archive.read(name)),flush_progress=lambda:None,
                  is_ota=False,sysinfo=SimpleNamespace(board_id=1,chip_id=2,device_class='j700ap'))
                scope['load_identity'](fake)
                assert fake.manifest==plistlib.loads(base64.b64decode(value['expectedManifest']))
    encoded=json.dumps(value,sort_keys=True,separators=(',',':'))+'\n'
    if a.write:OUTPUT.write_text(encoded)
    elif OUTPUT.read_text()!=encoded:raise SystemExit('stale native stub-file vectors')
    print('Verified native stub-file identity oracle and restore vectors')
if __name__=='__main__':main()
