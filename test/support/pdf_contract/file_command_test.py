"""Trusted subprocess seam: hostile programs are test-only, never PDF runtime opts."""
import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[3] / 'priv/pdf/bounded_command.py'

class BoundedCommandTest(unittest.TestCase):
    def test_dead_caller_is_rejected_before_native_spawn(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            argv = ['/usr/bin/python3', str(SCRIPT), d+'/out', d+'/err',
                    '1000', '1', '1073741824', '4096', '4096', '--caller-stdin',
                    '/usr/bin/python3', '-c',
                    'import pathlib,sys; pathlib.Path(sys.argv[1]).touch()', d+'/spawned']
            result = subprocess.run(argv, input=b'', capture_output=True, timeout=2)
            self.assertEqual(int(result.stdout.split()[1]), 6)
            self.assertFalse(pathlib.Path(d+'/spawned').exists())
            self.assertFalse(pathlib.Path(d+'/out').exists())

    def test_healthy_caller_pipe_does_not_delay_success(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            argv = ['/usr/bin/python3', str(SCRIPT), d+'/out', d+'/err',
                    '1000', '1', '1073741824', '4096', '4096', '--caller-stdin',
                    '/bin/printf', 'private']
            p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
            assert p.stdin is not None and p.stdout is not None and p.stderr is not None
            try:
                self.assertEqual(p.wait(timeout=2), 0)
                self.assertEqual(int(p.stdout.read().split()[1]), 0)
                self.assertEqual(pathlib.Path(d+'/out').read_bytes(), b'private')
                self.assertEqual(p.stderr.read(), b'')
            finally:
                p.stdin.close()
                p.stdout.close()
                p.stderr.close()

    def test_caller_watch_fails_closed_without_pipe(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            argv = ['/usr/bin/python3', str(SCRIPT), d+'/out', d+'/err',
                    '1000', '1', '1073741824', '4096', '4096', '--caller-stdin',
                    '/usr/bin/touch', d+'/spawned']
            result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=2)
            self.assertEqual(int(result.stdout.split()[1]), 3)
            self.assertFalse(pathlib.Path(d+'/spawned').exists())

    def test_cpu_budget_is_owned_tree_not_per_descendant(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        burn = 'import time; start=time.process_time(); exec("while time.process_time()-start < .65: pass")'
        code = 'import subprocess; ' + ('subprocess.run(["/usr/bin/python3","-c",' + repr(burn) + ']); ') * 3
        with tempfile.TemporaryDirectory() as d:
            result = module.run(['/usr/bin/python3', '-c', code], d+'/out', d+'/err',
                                5000, 1, 1073741824, 4096, 4096)
            print('TREE_CPU_RECEIPT', result)
            self.assertEqual(result['limit'], 5)
            self.assertLessEqual(result['cpu_ms'], 1100)

    def test_commands_share_finite_budget_without_reset_or_usage_double_count(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as d:
            burn = 'import time; start=time.process_time(); exec("while time.process_time()-start < .65: pass")'
            results = [module.run_budget(['/usr/bin/python3', '-c', burn],
                       d+'/'+str(i)+'out', d+'/'+str(i)+'err', 5000, 1,
                       1073741824, 4096, 4096, budget_path=d+'/budget') for i in range(2)]
            print('COMMAND_CPU_RECEIPT', results)
            self.assertEqual(results[0]['status'], 0)
            self.assertEqual(results[1]['limit'], 5)
            self.assertLessEqual(sum(r['cpu_ms'] for r in results), 1100)
            self.assertFalse(pathlib.Path(d+'/1out').exists())
            self.assertEqual(int(pathlib.Path(d+'/budget').read_text()), results[0]['cpu_ms'])
            # A distinct invocation has its own ledger; allow two fractional
            # stages under two seconds and deny the third before spawning.
            results = [module.run_budget(['/usr/bin/python3', '-c', burn],
                       d+'/b'+str(i)+'out', d+'/b'+str(i)+'err', 5000, 2,
                       1073741824, 4096, 4096, budget_path=d+'/budget2') for i in range(3)]
            self.assertEqual([r['limit'] for r in results], [0, 0, 5])
            self.assertLess(results[1]['cpu_ms'], 800)
            self.assertEqual(int(pathlib.Path(d+'/budget2').read_text()), sum(r['cpu_ms'] for r in results))

    def test_wait_usage_is_delta_not_cumulative_across_calls(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        burn = 'import time; start=time.process_time(); exec("while time.process_time()-start < .15: pass")'
        with tempfile.TemporaryDirectory() as d:
            results = [module.run(['/usr/bin/python3', '-c', burn], d+'/'+str(i)+'out',
                       d+'/'+str(i)+'err', 2000, 1, 1073741824, 4096, 4096) for i in range(2)]
            for result in results:
                self.assertEqual(result['status'], 0)
                self.assertGreaterEqual(result['cpu_ms'], 150)
                self.assertLess(result['cpu_ms'], 250)

    def test_cpu_watchdog_survives_closed_pipes_and_escaped_session(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        burn = 'import os; os.setsid(); exec("while True: pass")'
        code = ('import subprocess,os,sys; p=subprocess.Popen(["/usr/bin/python3","-c",'
                + repr(burn) + ']); open(sys.argv[1],"w").write(str(p.pid)); '
                'os.close(1); os.close(2); p.wait()')
        with tempfile.TemporaryDirectory() as d:
            result = module.run(['/usr/bin/python3', '-c', code, d+'/pid'],
                                d+'/out', d+'/err', 5000, 1, 1073741824, 4096, 4096)
            print('ESCAPED_CPU_RECEIPT', result)
            self.assertEqual(result['limit'], 5)
            self.assertLessEqual(result['cpu_ms'], 1100)
            self.assertFalse(pathlib.Path('/proc/'+pathlib.Path(d+'/pid').read_text()).exists())

    def test_captures_only_private_bounded_streams(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as d:
            result = module.run(['/bin/printf', 'private'], d + '/out', d + '/err',
                                1000, 1, 1073741824, 1024, 1024)
            self.assertEqual(result['status'], 0)
            self.assertEqual(pathlib.Path(d + '/out').read_bytes(), b'private')
            self.assertNotIn('private', str(result))
            self.assertEqual(pathlib.Path(d + '/out').stat().st_mode & 0o777, 0o600)

    def test_child_output_is_private_at_creation(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as d:
            result = module.run(['/usr/bin/python3', '-c',
                'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("x")', d + '/text'],
                d + '/out', d + '/err', 1000, 1, 1073741824, 1024, 1024)
            self.assertEqual(result['status'], 0)
            self.assertEqual(pathlib.Path(d + '/text').stat().st_mode & 0o777, 0o600)

    def test_real_subprocess_resource_envelope(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        import os
        import time
        cases = [
            ('stdout', 'import os; os.write(1,b"x"*1000000)', 1000, 1, 1073741824, 4096, 1024, 2),
            ('stderr', 'import os; os.write(2,b"x"*1000000)', 1000, 1, 1073741824, 4096, 1024, 2),
            ('cpu', 'while True: pass', 3000, 1, 1073741824, 4096, 4096, 5),
            ('memory', 'x=bytearray(100000000)', 1000, 1, 33554432, 4096, 4096, 0),
            ('file', 'import sys; open(sys.argv[1],"wb").write(b"x"*100000)', 1000, 1, 1073741824, 4096, 4096, 0),
            ('wall', 'import time; time.sleep(10)', 50, 1, 1073741824, 4096, 4096, 1),
            ('closed-pipes', 'import os,time; os.close(1); os.close(2); time.sleep(10)', 50, 1, 1073741824, 4096, 4096, 1),
        ]
        for name, code, wall, cpu, memory, files, diag, limit in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as d:
                result = module.run(['/usr/bin/python3', '-c', code, d + '/text'],
                    d + '/out', d + '/err', wall, cpu, memory, files, diag)
                self.assertEqual(result['limit'], limit)
                self.assertNotEqual(result['status'], 0)
                self.assertLessEqual(result['stdout_bytes'] + result['stderr_bytes'], diag)
                self.assertLess(result['duration_ms'], 3500)
                if name == 'file':
                    self.assertLessEqual(pathlib.Path(d + '/text').stat().st_size, files)
        with tempfile.TemporaryDirectory() as d:
            code = 'import subprocess,sys,time; p=subprocess.Popen(["/bin/sleep","10"]); open(sys.argv[1],"w").write(str(p.pid)); time.sleep(10)'
            result = module.run(['/usr/bin/python3', '-c', code, d + '/pid'],
                d + '/out', d + '/err', 100, 1, 1073741824, 4096, 4096)
            self.assertEqual(result['limit'], 1)
            pid = pathlib.Path(d + '/pid').read_text()
            stat = pathlib.Path('/proc/' + pid + '/stat')
            time.sleep(0.02)
            self.assertTrue(not stat.exists() or stat.read_text().split()[2] == 'Z')

    def test_timeout_reaps_descendants_that_start_a_new_session(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        import os
        import signal
        import time
        with tempfile.TemporaryDirectory() as d:
            code = 'import subprocess,sys,time; p=subprocess.Popen(["/usr/bin/python3","-c","import os,time; os.setsid(); time.sleep(10)"]); open(sys.argv[1],"w").write(str(p.pid)); time.sleep(10)'
            result = module.run(['/usr/bin/python3', '-c', code, d + '/pid'],
                d + '/out', d + '/err', 150, 1, 1073741824, 4096, 4096)
            self.assertEqual(result['limit'], 1)
            pid = int(pathlib.Path(d + '/pid').read_text())
            stat = pathlib.Path('/proc/' + str(pid) + '/stat')
            try:
                time.sleep(0.02)
                self.assertTrue(not stat.exists() or stat.read_text().split()[2] == 'Z')
            finally:
                if stat.exists():
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_ocr_child_scratch_and_home_stay_in_private_workspace(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as d:
            code = 'import os,tempfile; assert all(os.environ[k] == os.environ["TMPDIR"] for k in ["TMP","TEMP","HOME"]); f=tempfile.NamedTemporaryFile(delete=False); print(f.name)'
            result = module.run(['/usr/bin/python3', '-c', code], d + '/out', d + '/err',
                                1000, 1, 1073741824, 4096, 4096, scratch_dir=d)
            self.assertEqual(result['status'], 0)
            created = pathlib.Path(d + '/out').read_text().strip()
            self.assertEqual(pathlib.Path(created).parent, pathlib.Path(d))
            self.assertEqual(pathlib.Path(created).stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless(pathlib.Path('/tiny').exists(), 'quota-mounted image contract only')
    def test_kernel_quota_bounds_sum_of_files_not_just_each_file(self):
        spec = importlib.util.spec_from_file_location('bounded', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(module.workspace_quota('/tiny', 4194304))
        self.assertFalse(module.workspace_quota('/tiny', 1048576))
        with tempfile.TemporaryDirectory(dir='/tiny') as d:
            self.assertFalse(module.workspace_quota(d, 4194304))
            code = 'import pathlib,sys; d=pathlib.Path(sys.argv[1]); [(d/str(i)).write_bytes(b"x"*524288) for i in range(16)]'
            result = module.run(['/usr/bin/python3', '-c', code, d], d + '/out', d + '/err',
                                2000, 2, 1073741824, 1048576, 4096, scratch_dir=d)
            self.assertEqual(result['limit'], 4)
            self.assertNotEqual(result['status'], 0)
            files = list(pathlib.Path(d).iterdir())
            self.assertGreater(len(files), 4)
            self.assertLessEqual(sum(p.stat().st_size for p in files), 4194304)
            self.assertLessEqual(max(p.stat().st_size for p in files), 1048576)

if __name__ == '__main__':
    unittest.main()
