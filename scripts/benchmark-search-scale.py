"""Linux host retrieval and refresh fixture using synthetic unit vectors, never neural inference.

Build a release helper from this checkout. Creates/discards a private ~2 GB SQLite index.
100,000 metadata rows, 200 existing tiny files and constant 768-dimensional unit vectors do
not represent a real file corpus, model relevance, UI latency or physical GPU/NPU performance.
The primary scale uses 100 uncached queries; larger scales default to 20/10 exploratory samples.
"""
import argparse,hashlib,json,os,platform,queue,shutil,sqlite3,statistics,struct,subprocess,sys,tempfile,threading,time
from pathlib import Path


def main():
    repo=Path(__file__).resolve().parents[1]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--samples',type=int,nargs=3,default=[100,20,10],metavar=('small','medium','large'))
    parser.add_argument('--vectors',type=int,nargs=3,default=[70_000,250_000,1_000_000],metavar=('small','medium','large'))
    args=parser.parse_args()
    if not sys.platform.startswith('linux'):parser.error('This /proc memory fixture is Linux-only; use benchmark-search-ui.js for installed Windows latency.')
    if args.samples[0]<100 or any(n<10 or n>199 for n in args.samples):parser.error('Use 100–199 primary samples and 10–199 samples at the other scales.')
    if not (1 <= args.vectors[0] <= 100_000 < args.vectors[1] < args.vectors[2] <= 1_000_000):parser.error('Use a first scale up to 100k and increasing larger scales up to one million.')
    helper=args.helper.resolve();out=args.output
    out.parent.mkdir(parents=True,exist_ok=True)
    env=dict(os.environ,
             DIGUP_ACCELERATOR='openvino-npu',DIGUP_OPENVINO_PYTHON=sys.executable,
             DIGUP_OPENVINO_WORKER=str(repo/'tests/applications/synthetic-worker.py'),DIGUP_APP_TEST_DELAY='0')
    def stats(values):
        values=sorted(values)
        return {'samples':len(values),'medianMs':statistics.median(values),'p95Ms':values[(len(values)*95+99)//100-1],'maxMs':max(values)}
    report={'synthetic':True,'physicalAcceleratorValidated':False,'platform':platform.platform(),
            'scope':'Linux release helper roundtrips, no UI/debounce/model; 100k catalog rows, 200 real fixture files',
            'build':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'stages':[],'requestedVectors':args.vectors,'requestedSamples':args.samples}
    report['binarySHA256']=hashlib.sha256(helper.read_bytes()).hexdigest()
    report['sourcePatchSHA256']=hashlib.sha256(subprocess.check_output(['git','diff','HEAD','--','Sources/DigUpKit/Platform/Portable/Math+Portable.swift','Sources/digup/SearchService.swift','Sources/digup/FileAvailability.swift','Tests/DigUpKitTests/SearchReadersTests.swift'],cwd=repo)).hexdigest()
    source_hash=hashlib.sha256()
    for name in ['Package.swift','Sources/CSearchMath/conversion.c','Sources/CSearchMath/include/CSearchMath.h','Sources/DigUpKit/Platform/Portable/Math+Portable.swift','Sources/digup/SearchService.swift','Sources/digup/FileAvailability.swift']:
        source_hash.update(name.encode()+b'\0'+(repo/name).read_bytes()+b'\0')
    report['sourceFilesSHA256']=source_hash.hexdigest()
    report['cpu']=next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),platform.processor())
    report['physicalMemory']=next(line for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemTotal:'))
    report['swift']=subprocess.check_output([shutil.which('swift') or 'swift','--version'],text=True).strip()
    with tempfile.TemporaryDirectory(prefix='digup-host-scale-') as temp:
        root=Path(temp);bundle=root/'bundle';bundle.mkdir();(bundle/'manifest.json').write_text('{}')
        env.update(DIGUP_OPENVINO_MODELS=str(bundle),DIGUP_APP_TEST_LOG=str(root/'worker.jsonl'))
        log=(root/'stderr.log').open('w');responses=queue.Queue();received={};events=[];seq=0
        process=subprocess.Popen([str(helper),'search-service','--index',str(root/'index')],
            env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True)
        def read():
            for line in process.stdout:responses.put((time.perf_counter(),json.loads(line)))
        threading.Thread(target=read,daemon=True).start()
        def send(**fields):
            nonlocal seq
            seq+=1;process.stdin.write(json.dumps(dict(id=seq,**fields))+'\n');process.stdin.flush();return seq
        def wait(identifier,timeout=120):
            deadline=time.perf_counter()+timeout
            while identifier not in received:
                at,reply=responses.get(timeout=max(.01,deadline-time.perf_counter()))
                if 'id' in reply:received[reply['id']]=(at,reply)
                else:events.append(reply)
            return received.pop(identifier)
        def call(**fields):return wait(send(**fields))[1]
        def rss():
            try:
                for line in Path(f'/proc/{process.pid}/status').read_text().splitlines():
                    if line.startswith('VmRSS:'):return int(line.split()[1])*1024
            except FileNotFoundError:return 0
            return 0
        peak=[0];sampling=[True]
        def sample():
            while sampling[0]:peak[0]=max(peak[0],rss());time.sleep(.025)
        threading.Thread(target=sample,daemon=True).start()
        try:
            path=call(op='status')['index'];documents=root/'documents';documents.mkdir()
            for n in range(200):(documents/f'record{n:06}.txt').write_text('Synthetic fixture only.\n')
            db=sqlite3.connect(path);db.execute('PRAGMA journal_mode=WAL');db.execute('PRAGMA synchronous=NORMAL')
            db.executemany('INSERT INTO files(id,path,kind,size,mtime,inode,device,state) VALUES(?,?,?,?,?,?,?,?)',
                ((n+1,str(documents/f'record{n:06}.txt'),'doc',20,1,n+1,1,'done') for n in range(100_000)))
            db.executemany('INSERT INTO segments(id,file,kind,modality,excerpt) VALUES(?,?,?,?,?)',
                ((n+1,n+1,'chunk','text','A synthetic fixture') for n in range(100_000)))
            db.executemany('INSERT INTO fts(rowid,name,body) VALUES(?,?,?)',
                ((n+1,f'record{n:06}',f'Synthetic fixture entry {n}') for n in range(100_000)))
            db.execute('INSERT INTO meta(key,value) VALUES(?,?)',('vector_source','unit-test/synthetic-vectors@1234567 synthetic-unit-v1 synthetic-f32'))
            db.commit();db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            call(op='reload');time.sleep(.5)
            words=[]
            for n in range(101):
                started=time.perf_counter();reply=call(op='search',q=f'record{n:06}',meaning=False,facets=True,limit=40)
                assert reply['hits'] and reply['hits'][0]['path'].endswith(f'record{n:06}.txt'),reply
                if n:words.append((time.perf_counter()-started)*1000)
            report['keyword100k']=stats(words);print('100k keyword',report['keyword100k'],flush=True)
            call(op='prewarm')
            vector=struct.pack('<'+'e'*768,1,*([0]*767))
            previous=0
            for count,samples in zip(args.vectors,args.samples):
                if previous==0:db.execute('UPDATE segments SET vec=? WHERE id<=?',(vector,count))
                else:
                    if previous<100_000:db.execute('UPDATE segments SET vec=? WHERE id>?',(vector,previous))
                    start=max(100_000,previous)
                    db.executemany('INSERT INTO segments(id,file,kind,modality,vec) VALUES(?,?,?,?,?)',
                        ((n+1,n%100_000+1,'chunk','text',vector) for n in range(start,count)))
                db.commit()
                events.clear();peak[0]=rss();started=time.perf_counter();call(op='reload')
                during=[];ready=False;deadline=time.perf_counter()+120
                while not ready:
                    begin=time.perf_counter();call(op='search',q='record000001',meaning=False,limit=40)
                    during.append((time.perf_counter()-begin)*1000)
                    ready=any(event.get('event')=='search_index' and event.get('state')=='ready' and event.get('vectors')==count for event in events)
                    assert time.perf_counter()<deadline,(count,events[-5:])
                    if not ready:time.sleep(.01)
                load_ms=(time.perf_counter()-started)*1000;latencies=[];last=None
                for n in range(samples+1):
                    begin=time.perf_counter();last=call(op='search',q=f'record{n:06} scale{count}',meaning=True,facets=True,limit=40)
                    assert last['meaning'] and last.get('status')!='superseded',last
                    if n:latencies.append((time.perf_counter()-begin)*1000)
                item={'vectors':count,'refreshMs':load_ms,'keywordDuringRefresh':stats(during),'retrievalRoundtrip':stats(latencies),
                      'retrievalSamplesMs':latencies,'keywordDuringRefreshSamplesMs':during,
                      'peakHelperRssBytes':peak[0],'lastPhases':last['ms'],'databaseBytes':Path(path).stat().st_size}
                report['stages'].append(item);out.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(item),flush=True)
                previous=count;db.execute('PRAGMA wal_checkpoint(PASSIVE)')
            db.close()
        finally:
            sampling[0]=False
            if process.poll() is None:
                try:send(op='quit');process.wait(timeout=10)
                except Exception:process.kill();process.wait()
            log.close()
    print('PASS: host scale fixtures; synthetic-only, no neural/hardware or relevance claims',flush=True)

if __name__ == "__main__":
    main()
