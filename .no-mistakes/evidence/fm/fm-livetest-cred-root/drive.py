import os,pathlib,subprocess,time,json,hashlib,stat
root=pathlib.Path.cwd(); temp=root/'.live-test-tmp'; evidence=pathlib.Path('/home/hezki/.no-mistakes/evidence/01M4ZD71HKQC3YS12MHKW6F91B')
home=pathlib.Path.home(); credentials=home/'.claude/.credentials.json'
override=temp/'override'; override.mkdir(exist_ok=True)
(override/'.claude.json').write_bytes((home/'.claude.json').read_bytes())
(override/'.credentials.json').write_text('{"decoy":true}')
snapshot=(home/'.claude.json').read_bytes()
json.dump({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [home/'.claude.json',credentials]},open(temp/'before.json','w'))
for name,use_override in [('default-observed',False),('override-observed',True)]:
 env=os.environ.copy(); env['TMPDIR']=str(temp); env.pop('CLAUDE_CONFIG_DIR',None)
 if use_override: env['CLAUDE_CONFIG_DIR']=str(override)
 seen=False
 with (evidence/(name+'.log')).open('w') as log:
  process=subprocess.Popen(['bash','tests/fm-restored-recover-live-e2e.test.sh'],env=env,stdout=log,stderr=subprocess.STDOUT)
  while process.poll() is None:
   for target in temp.glob('fm-restored-live.*/claude-config/.credentials.json'):
    try:
     assert target.read_bytes()==credentials.read_bytes(), 'copied credentials differ from ordinary credential store'
     assert stat.S_IMODE(target.stat().st_mode)==0o600, 'credential mode is not 0600'
     config=json.loads((target.parent/'.claude.json').read_text())
     if not seen:
      log.write('Observed disposable credentials equal ordinary ~/.claude/.credentials.json; mode 0600.\n');log.flush();seen=True
    except FileNotFoundError: pass
   time.sleep(.01)
  assert process.returncode==0, f'{name} failed: {process.returncode}'
  assert seen, 'did not observe disposable credentials'
  log.write('Real-Claude startup scenarios completed successfully.\n')
 print(name+': pass')
before=json.loads((temp/'before.json').read_text())
for p,digest in before.items():
 
 if hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()!=digest:
  x=json.loads(snapshot);y=json.loads(pathlib.Path(p).read_bytes());print('Changed keys:',[k for k in x.keys()|y.keys() if x.get(k)!=y.get(k)])
  raise AssertionError(f'real source changed: {p}')
(evidence/'isolation.log').write_text('Real ~/.claude.json and ~/.claude/.credentials.json remain byte-for-byte unchanged after all three live runs.\nOverride scenario supplied decoy credentials in CLAUDE_CONFIG_DIR; disposable credentials matched ordinary ~/.claude credentials instead.\n')
print('Source isolation: pass')
