import os,ctypes,struct,select,subprocess,time,signal,json
from pathlib import Path
root=Path.cwd()
libc=ctypes.CDLL(None,use_errno=True)
for successor in (0,1):
 home=root/'.test-tmp'/f'live-marker-{successor}'
 for part in ('state','data','config'): (home/part).mkdir(parents=True,exist_ok=True)
 fd=libc.inotify_init1(os.O_NONBLOCK)
 libc.inotify_add_watch(fd,os.fsencode(home/'state'),0x100)
 env=dict(os.environ,FM_HOME=str(home),FM_POLL='1',FM_SIGNAL_GRACE='10',FM_CHECK_INTERVAL='999999',FM_WATCH_HANDLING_SUCCESSOR=str(successor))
 p=subprocess.Popen(['bin/fm-watch-checkpoint.sh','--seconds','2'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 stopped=None; observation={}
 deadline=time.monotonic()+5
 while time.monotonic()<deadline and p.poll() is None and stopped is None:
  if not select.select([fd],[],[],.05)[0]: continue
  data=os.read(fd,65536); offset=0
  while offset<len(data):
   wd,mask,cookie,length=struct.unpack_from('iIII',data,offset); name=data[offset+16:offset+16+length].split(b'\0')[0]; offset+=16+length
   if name==b'.watcher-down.lock':
    try:
     pid=int((home/'state/.watch.lock/pid').read_text()); os.kill(pid,signal.SIGSTOP); stopped=pid
     marker=home/'state/.watcher-down.lock'
     observation={'watcher_pid':pid,'marker_lock_present_when_stopped':marker.exists(),'marker_owner':(marker/'pid').read_text().strip() if marker.exists() else None}
    except (FileNotFoundError,ProcessLookupError): pass
    break
 if stopped:
  time.sleep(2.5)
  os.kill(stopped,signal.SIGCONT)
 try: out,err=p.communicate(timeout=20)
 except subprocess.TimeoutExpired:
  p.kill(); out,err=p.communicate(); observation['driver_timeout']=True
 observation.update(successor=successor,exit=p.returncode,stdout=out,stderr=err,watch_lock_pid_present=(home/'state/.watch.lock/pid').exists())
 print(json.dumps(observation),flush=True)
 os.close(fd)
