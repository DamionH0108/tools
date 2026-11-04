import os
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'panel'))
import prepare_environment as prep

class PrepareTests(unittest.TestCase):
    def exercise(self,answer,backup_error=False):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            home=Path(tmp); root=home/'.claude'; root.mkdir()
            secret=home/'.claude.json';secret.write_text('{"userID":"fixture-only-id"}')
            (root/'skills').mkdir();(root/'skills'/'mine.md').write_text('keep')
            outside=home/'outside';outside.mkdir();(outside/'sentinel').touch()
            (root/'sessions').symlink_to(outside,target_is_directory=True)
            (root/'unrelated').touch();(home/'.claude.json.backup.123').touch()
            keys=set(prep.SERVICES)
            def fake_key(k,delete=False):
                if delete: keys.remove(k)
                return k in keys
            for target,value in [('prepare_environment.Path.home',lambda:home),('prepare_environment.os.isatty',lambda _:True),('prepare_environment.os.geteuid',lambda:501),('prepare_environment.check_processes',lambda:None),('prepare_environment.key',fake_key),('builtins.input',lambda _:answer)]:stack.enter_context(patch(target,value))
            stack.enter_context(redirect_stdout(StringIO()))
            if backup_error:
                stack.enter_context(patch.object(prep,'backup',side_effect=OSError('backup failed')))
                with self.assertRaises(OSError): prep.main()
            else: prep.main()
            if answer!='SWITCH ACCOUNT' or backup_error:
                self.assertTrue(secret.exists());self.assertEqual(keys,set(prep.SERVICES))
                if not backup_error:self.assertFalse(list(home.glob('Claude-setup-backup-*')))
            else:
                self.assertEqual(prep.targets(home),[]);self.assertFalse(keys)
                saved=next(home.glob('Claude-setup-backup-*'))
                self.assertEqual((saved/'personal/skills/mine.md').read_text(),'keep')
                self.assertNotIn('fixture-only-id',(saved/'identifier-digests.json').read_text())
            self.assertTrue((outside/'sentinel').exists());self.assertTrue((root/'unrelated').exists())
            self.assertTrue((root/'skills/mine.md').exists())
    def test_cancel(self):self.exercise('no')
    def test_execute(self):self.exercise('SWITCH ACCOUNT')
    def test_failed_backup(self):self.exercise('SWITCH ACCOUNT',True)
    def test_refuse_symlink_root(self):
        with tempfile.TemporaryDirectory() as d:
            home=Path(d);(home/'.claude').symlink_to(home)
            with self.assertRaises(ValueError):prep.targets(home)
