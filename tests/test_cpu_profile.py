import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch


SOURCE = Path(__file__).resolve().parents[1] / 'collectors' / 'cpu_pulse.py'
spec = importlib.util.spec_from_file_location('cpu_pulse', SOURCE)
cpu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cpu)


class ReadProfileTests(unittest.TestCase):
    def test_valid_names(self):
        for name in ('performance', 'balanced', 'power-saver'):
            with self.subTest(name=name), patch.object(cpu, 'run', return_value=json.dumps({'data': name})) as run:
                self.assertEqual(cpu.read_profile(), name)
                run.assert_called_once_with([
                    'busctl', '--system', 'get-property',
                    'net.hadess.PowerProfiles', '/net/hadess/PowerProfiles',
                    'net.hadess.PowerProfiles', 'ActiveProfile', '--json=short',
                ])

    def test_invalid_values_read_as_empty(self):
        for value in (None, 42, True, '', 'unknown', 'None', ' balanced ', [], {}):
            with self.subTest(value=value), patch.object(cpu, 'run', return_value=json.dumps({'data': value})):
                self.assertEqual(cpu.read_profile(), '')

    def test_malformed_answers_read_as_empty(self):
        for answer in ('not json', '', '{}', 'null', '[]'):
            with self.subTest(answer=answer), patch.object(cpu, 'run', return_value=answer):
                self.assertEqual(cpu.read_profile(), '')

    def test_helper_exceptions_read_as_empty(self):
        errors = (
            OSError('unavailable'), subprocess.SubprocessError('failed'),
            subprocess.TimeoutExpired('busctl', 2),
            subprocess.CalledProcessError(1, 'busctl'),
            UnicodeDecodeError('utf-8', b'\xff', 0, 1, 'invalid byte'),
            ValueError('invalid'), TypeError('invalid'), KeyError('data'),
        )
        for error in errors:
            with self.subTest(error=type(error).__name__), patch.object(cpu, 'run', side_effect=error):
                self.assertEqual(cpu.read_profile(), '')


class CurrentProfileTests(unittest.TestCase):
    def setUp(self):
        self.cache = {'value': '', 'at': 0.0, 'stamp': 0.0}
        self.stamp = Mock()
        self.stamp.stat.return_value.st_mtime = 7.0
        for patcher in (
            patch.object(cpu, '_profile', self.cache),
            patch.object(cpu, 'PROFILE_STAMP', self.stamp),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_valid_name_is_cached(self):
        with patch.object(cpu, 'read_profile', return_value='balanced') as reader, patch.object(cpu.time, 'monotonic', side_effect=[100.0, 101.0]):
            self.assertEqual(cpu.current_profile(), 'balanced')
            self.assertEqual(cpu.current_profile(), 'balanced')
        reader.assert_called_once_with()
        self.assertEqual(self.cache, {'value': 'balanced', 'at': 100.0, 'stamp': 7.0})

    def test_empty_read_keeps_value_and_refreshes_clock_and_stamp(self):
        self.cache.update(value='performance', at=100.0, stamp=6.0)
        with patch.object(cpu, 'read_profile', return_value='') as reader, patch.object(cpu.time, 'monotonic', side_effect=[101.0, 102.0, 132.0, 133.0]):
            for _ in range(4):
                self.assertEqual(cpu.current_profile(), 'performance')
        self.assertEqual(reader.call_count, 2)
        self.assertEqual(self.cache, {'value': 'performance', 'at': 132.0, 'stamp': 7.0})

    def test_startup_failure_with_missing_stamp_stays_empty_and_is_cached(self):
        self.stamp.stat.side_effect = FileNotFoundError()
        with patch.object(cpu, 'read_profile', return_value='') as reader, patch.object(cpu.time, 'monotonic', side_effect=[100.0, 101.0]):
            self.assertEqual(cpu.current_profile(), '')
            self.assertEqual(cpu.current_profile(), '')
        reader.assert_called_once_with()
        self.assertEqual(self.cache, {'value': '', 'at': 100.0, 'stamp': 0.0})

    def test_helper_failure_preserves_cache_and_refreshes_metadata(self):
        self.cache.update(value='balanced', at=1.0)
        with patch.object(cpu, 'run', side_effect=OSError('unavailable')), patch.object(cpu.time, 'monotonic', return_value=100.0):
            self.assertEqual(cpu.current_profile(), 'balanced')
        self.assertEqual(self.cache, {'value': 'balanced', 'at': 100.0, 'stamp': 7.0})


if __name__ == '__main__':
    unittest.main()
