import base64, hashlib, json, os, pathlib, subprocess, tempfile, unittest
SCRIPT=pathlib.Path(__file__).resolve().parents[1]/'Sources/HarborSSH/Resources/WorkspaceRuntime/files.py'
class WorkspaceRuntimeTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='harbor-remote-test-');self.addCleanup(self.tmp.cleanup);self.root=pathlib.Path(self.tmp.name)
  self.home=self.root/'.home';self.home.mkdir()
 def call(self,op,path,**args):
  return subprocess.run(['/usr/bin/python3',str(SCRIPT)],input=json.dumps(dict(op=op,path=str(path),**args)).encode(),capture_output=True,timeout=10,env={**os.environ,'HOME':str(self.home)})
 def test_json_paths_binary_and_hidden(self):
  name="中文 ' $(echo nope)\nfile.bin";data=bytes(range(256))*100
  file=self.root/name;file.write_bytes(data);(self.root/'.hidden').touch();(self.root/'dir').mkdir()
  listing=self.call('list',self.root);self.assertEqual(listing.returncode,0,listing.stderr)
  self.assertEqual([x['name'] for x in json.loads(listing.stdout)['entries']],['dir',name])
  result=self.call('read',file,limit=len(data));self.assertEqual(result.stdout,data);self.assertEqual(result.returncode,0)
  self.assertNotEqual(self.call('read',file,limit=10).returncode,0)
 def test_a_name_that_is_not_utf8_does_not_make_its_folder_unlistable(self):
  try: os.close(os.open(os.fsencode(str(self.root))+b'/caf\xe9.txt',os.O_CREAT|os.O_WRONLY))
  except OSError: self.skipTest('this filesystem only takes UTF-8 names')
  (self.root/'plain.txt').touch()
  listing=self.call('list',self.root);self.assertEqual(listing.returncode,0,listing.stderr)
  # What the app's decoder is given: text that is valid UTF-8 and holds no lone surrogate.
  entries=json.loads(listing.stdout.decode('utf-8'))['entries']
  self.assertEqual([x['name'] for x in entries],['caf\ufffd.txt','plain.txt'])
  self.assertNotIn(b'\\ud', listing.stdout)
 def test_save_conflict_symlink_mode_and_exclusive_create(self):
  file=self.root/'file.py';file.write_text('before');file.chmod(0o755);link=self.root/'link';link.symlink_to(file)
  digest=hashlib.sha256(b'before').hexdigest();payload=base64.b64encode('after 中文'.encode()).decode()
  result=self.call('write',link,data=payload,digest=digest);self.assertEqual(result.returncode,0,result.stderr)
  self.assertTrue(link.is_symlink());self.assertEqual(file.read_text(),'after 中文');self.assertEqual(file.stat().st_mode&0o777,0o755)
  self.assertNotEqual(self.call('write',file,data=payload,digest=digest).returncode,0)
  self.assertNotEqual(self.call('create',file).returncode,0)
  self.assertEqual(file.read_text(),'after 中文')
 def test_directory_not_read_as_file(self):
  self.assertNotEqual(self.call('read',self.root,limit=1024).returncode,0)
 def test_html_assets_cannot_escape_preview_root(self):
  site=self.root/'site';site.mkdir();asset=site/'chart.js';asset.write_bytes(b'window.loaded=true')
  secret=self.root/'secret';secret.write_bytes(b'not public');(site/'escape.js').symlink_to(secret)
  (site/'.env').write_bytes(b'hidden');(site/'alias.js').symlink_to(asset)
  result=self.call('read',site/'alias.js',previewRoot=str(site),limit=1024)
  self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,asset.read_bytes())
  for path in [secret,site/'escape.js',site/'.env',site]:
   self.assertNotEqual(self.call('read',path,previewRoot=str(site),limit=1024).returncode,0)
 def test_refresh_batches_changed_directories_and_isolates_errors(self):
  logs=self.root/'logs';logs.mkdir();listing=json.loads(self.call('list',logs).stdout)
  directories=[dict(path=str(logs),stamp=listing['stamp']),dict(path=str(self.root/'missing'))]
  result=json.loads(self.call('refresh',self.root,directories=directories).stdout)
  self.assertIsNone(result['directories'][0]['listing']);self.assertIsNotNone(result['directories'][1]['error'])
  video=logs/"视频 ' $(not-a-command).mp4";video.write_bytes(b'new video')
  (logs/'.hidden').touch()
  result=json.loads(self.call('refresh',self.root,directories=directories,files=[str(video)]).stdout)
  self.assertEqual([x['name'] for x in result['directories'][0]['listing']['entries']],[video.name])
  self.assertEqual(result['files'][0]['entry']['size'],9)
  stamp=result['directories'][0]['listing']['stamp']
  video.write_bytes(b'updated existing video')
  result=json.loads(self.call('refresh',self.root,directories=[dict(path=str(logs),stamp=stamp)],files=[str(video)]).stdout)
  self.assertIsNone(result['directories'][0]['listing']);self.assertEqual(result['files'][0]['entry']['size'],22)
  self.assertNotEqual(self.call('refresh',self.root,directories=[dict(path=str(logs))]*33).returncode,0)
 def test_html_media_ranges_are_bounded_versioned_and_confined(self):
  site=self.root/'site';site.mkdir();video=site/'large.mp4';data=bytes(range(256))
  with video.open('wb') as f:
   f.write(data);f.seek(30*1024*1024);f.write(data)
  result=self.call('preview-stat',video,previewRoot=str(site));self.assertEqual(result.returncode,0,result.stderr)
  info=json.loads(result.stdout);self.assertEqual(info['size'],30*1024*1024+256)
  def read(offset,count,version=info['version']):
   return self.call('preview-read',video,previewRoot=str(site),offset=offset,count=count,version=version)
  result=read(info['size']-256,256);self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,data)
  for offset,count in [(-1,1),(info['size'],1),(0,1024*1024+1),(0,0)]: self.assertNotEqual(read(offset,count).returncode,0)
  self.assertNotEqual(read(0,1,'stale').returncode,0)
  video.write_bytes(b'changed');self.assertNotEqual(read(0,1).returncode,0)
  secret=self.root/'secret';secret.write_text('secret');(site/'escape.mp4').symlink_to(secret)
  (site/'.env').write_text('hidden');os.mkfifo(site/'pipe.mp4')
  for path in [secret,site/'escape.mp4',site/'.env',site/'pipe.mp4',site]:
   self.assertNotEqual(self.call('preview-stat',path,previewRoot=str(site)).returncode,0)
  self.assertNotEqual(self.call('preview-stat',video).returncode,0)
 def test_copy_move_rename_trash_and_conflicts(self):
  folder=self.root/"folder 中文 ' $(no)";folder.mkdir();(folder/'main.py').write_text('hello')
  destination=self.root/'destination';destination.mkdir()
  copied=self.call('copy',folder,parent=str(self.root));self.assertEqual(copied.returncode,0,copied.stderr)
  copy=pathlib.Path(json.loads(copied.stdout)['path']);self.assertEqual((copy/'main.py').read_text(),'hello')
  moved=self.call('move',copy,parent=str(destination));self.assertEqual(moved.returncode,0,moved.stderr);self.assertFalse(copy.exists())
  moved_path=pathlib.Path(json.loads(moved.stdout)['path'])
  renamed=self.call('rename',moved_path,parent=str(destination),name='renamed');self.assertEqual(renamed.returncode,0,renamed.stderr)
  renamed_path=pathlib.Path(json.loads(renamed.stdout)['path'])
  self.assertNotEqual(self.call('move',folder,parent=str(destination),name='renamed').returncode,0)
  self.assertNotEqual(self.call('copy',folder,parent=str(folder)).returncode,0)
  trashed=self.call('trash',renamed_path);self.assertEqual(trashed.returncode,0,trashed.stderr)
  recovered=pathlib.Path(json.loads(trashed.stdout)['path']);self.assertFalse(renamed_path.exists());self.assertEqual((recovered/'main.py').read_text(),'hello')
  self.assertEqual(json.loads((recovered.parent/'restore.json').read_text())['original'],str(renamed_path))
 def test_streamed_roundtrip_rejects_traversal_and_preserves_binary(self):
  import struct
  folder=self.root/'source';folder.mkdir();(folder/'目录').mkdir();data=bytes(range(256))*8192
  (folder/'目录'/'video.mp4').write_bytes(data);(folder/'link').symlink_to('目录/video.mp4')
  exported=self.call('export',folder);self.assertEqual(exported.returncode,0,exported.stderr)
  def imported(payload,name):
   request=base64.b64encode(json.dumps(dict(op='import',path=str(self.root),name=name)).encode()).decode()
   return subprocess.run(['/usr/bin/python3',str(SCRIPT),request],input=payload,capture_output=True,timeout=10)
  result=imported(exported.stdout,'copied');self.assertEqual(result.returncode,0,result.stderr)
  copied=pathlib.Path(json.loads(result.stdout)['path']);self.assertEqual((copied/'目录'/'video.mp4').read_bytes(),data);self.assertTrue((copied/'link').is_symlink())
  def record(path,kind,**values):
   data=json.dumps(dict(path=path,kind=kind,mode=493,**values)).encode();return struct.pack('!I',len(data))+data
  payload=record('../escape','directory')+b'\0'*4
  self.assertNotEqual(imported(payload,'invalid').returncode,0);self.assertFalse((self.root/'invalid').exists())
  payload=record('item','directory')+record('item/link','symlink',link='../../escape')+b'\0'*4
  self.assertNotEqual(imported(payload,'invalid').returncode,0)
  self.assertNotEqual(imported(exported.stdout[:100],'invalid').returncode,0)
if __name__=='__main__':unittest.main()
