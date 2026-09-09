#!/usr/bin/env python3
"""Exercise capture ordering and failure recovery without Docker/cloud access."""
import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('backup-compose-app.sh').resolve()
MOCK = r'''#!/usr/bin/env python3
import os,sys,pathlib,shutil
root=pathlib.Path(os.environ['FIXTURE'])
a=sys.argv[1:]
with (root/'events').open('a') as f: f.write(' '.join(a)+'\n')
if a[:2]==['compose','ps']:
 print('app\nworker\npostgres')
elif a[:2]==['compose','stop']:
 assert a[2:]==['app','worker'], a
 (root/'stopped').touch()
 if os.environ.get('FAIL_PHASE')=='stop': sys.exit(3)
elif a[:2]==['compose','start']:
 assert a[2:]==['app','worker'], a
 (root/'resumed').touch()
elif a[:2]==['compose','exec']:
 assert (root/'stopped').exists(), 'Database dump raced application writes'
 if os.environ.get('FAIL_PHASE')=='dump': sys.exit(4)
 print('database references record-42.txt')
elif a[:2]==['volume','inspect']: pass
elif a[0]=='run':
 assert (root/'stopped').exists() and not (root/'resumed').exists()
 if os.environ.get('FAIL_PHASE')=='archive': sys.exit(5)
 bind=a[a.index('-v', a.index('-v')+1)+1]
 out=pathlib.Path(bind.removesuffix(':/backup'))/'app_data.tar.gz'
 out.write_text('record-42.txt')
else: raise AssertionError(a)
'''
class BackupConsistency(unittest.TestCase):
 def run_case(self, phase=''):
  with tempfile.TemporaryDirectory() as temp:
   root=pathlib.Path(temp); (root/'app').mkdir(); (root/'bin').mkdir()
   (root/'app'/'compose.yml').write_text('services: {}\n')
   for name,body in {
    'docker':MOCK,
    'sudo':'#!/bin/sh\nexec "$@"\n',
    'age':'#!/bin/sh\nwhile [ "$1" != "-o" ]; do shift; done\ncp "$3" "$2"\n',
    'aws':'#!/bin/sh\nprintf "upload\\n" >> "$FIXTURE/events"\n',
   }.items():
    p=root/'bin'/name;p.write_text(body);p.chmod(0o755)
   config=root/'config.env';config.write_text(f'APP_DIR="{root}/app"\nBUCKET=test\nREGION=nyc3\nAGE_RECIPIENT=test\nVOLUME_NAMES=app_data\nAWS_ACCESS_KEY_ID=test\nAWS_SECRET_ACCESS_KEY=test\nPOSTGRES_SERVICE=postgres\nPOSTGRES_DATABASE=test\nPOSTGRES_USER=test\n')
   env={**os.environ,'PATH':str(root/'bin')+':'+os.environ['PATH'],'FIXTURE':str(root),'FAIL_PHASE':phase}
   result=subprocess.run(['bash',str(SCRIPT),str(config)],env=env,capture_output=True,text=True)
   events=(root/'events').read_text()
   self.assertTrue((root/'resumed').exists(), result.stderr)
   self.assertNotIn('start postgres',events)
   if phase:
    self.assertNotEqual(result.returncode,0,result.stdout)
    self.assertNotIn('upload',events)
   else:
    self.assertEqual(result.returncode,0,result.stderr)
    self.assertLess(events.index('stop app worker'),events.index('pg_dump'))
    self.assertLess(events.index('pg_dump'),events.index('run --rm'))
    self.assertLess(events.index('run --rm'),events.index('start app worker'))
    self.assertEqual(events.count('upload'),2)
 def test_capture_with_file_reference(self): self.run_case()
 def test_partial_stop_resumes(self): self.run_case('stop')
 def test_dump_failure_resumes_without_upload(self): self.run_case('dump')
 def test_archive_failure_resumes_without_upload(self): self.run_case('archive')
if __name__=='__main__': unittest.main()
