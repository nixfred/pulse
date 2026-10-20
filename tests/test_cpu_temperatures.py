import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / 'collectors' / 'cpu_pulse.py'
spec = importlib.util.spec_from_file_location('cpu_pulse', SOURCE)
cpu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cpu)


class TemperaturesTests(unittest.TestCase):
    def setUp(self):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.hwmon = Path(root.name) / 'hwmon'
        self.thermal = Path(root.name) / 'thermal'
        self.hwmon.mkdir()
        self.thermal.mkdir()
        for patcher in (patch.object(cpu, 'HWMON', self.hwmon), patch.object(cpu, 'THERMAL', self.thermal)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def sensor(self, index, name, readings):
        """One hwmon directory: readings maps a temp index to (label or None, millidegrees)."""
        h = self.hwmon / ('hwmon' + str(index))
        h.mkdir()
        (h / 'name').write_text(name + '\n')
        for n, (label, milli) in readings.items():
            (h / ('temp%d_input' % n)).write_text(str(milli) + '\n')
            if label is not None:
                (h / ('temp%d_label' % n)).write_text(label + '\n')

    def test_k10temp_reads_tctl_as_the_package(self):
        self.sensor(0, 'nvme', {1: ('Composite', 41850)})
        self.sensor(7, 'k10temp', {1: ('Tctl', 47500), 3: ('Tccd1', 38875)})
        package, cores, sensors = cpu.temperatures()
        self.assertEqual(package, 47.5)
        self.assertEqual(cores, {})
        self.assertEqual(sensors, [{'label': 'Tctl', 'temp': 47.5}, {'label': 'Tccd1', 'temp': 38.875}])

    def test_tdie_wins_over_an_offset_tctl(self):
        self.sensor(1, 'k10temp', {1: ('Tctl', 70000), 2: ('Tdie', 50000)})
        self.assertEqual(cpu.temperatures()[0], 50.0)

    def test_zenpower_is_read_the_same_way(self):
        self.sensor(1, 'zenpower', {1: ('Tdie', 55000), 2: ('Tctl', 55000), 3: ('Tccd1', 49000)})
        self.assertEqual(cpu.temperatures()[0], 55.0)

    def test_two_sockets_report_the_hotter_package(self):
        self.sensor(1, 'k10temp', {1: ('Tctl', 61000)})
        self.sensor(2, 'k10temp', {1: ('Tctl', 66000)})
        self.assertEqual(cpu.temperatures()[0], 66.0)

    def test_pre_zen_unlabelled_reading_is_the_package(self):
        self.sensor(1, 'k10temp', {1: (None, 45000)})
        package, _, sensors = cpu.temperatures()
        self.assertEqual(package, 45.0)
        self.assertEqual(sensors, [{'label': 'k10temp', 'temp': 45.0}])

    def test_coretemp_is_unchanged(self):
        self.sensor(1, 'coretemp', {1: ('Package id 0', 62000), 2: ('Core 0', 60000), 3: ('Core 1', 58000)})
        package, cores, _ = cpu.temperatures()
        self.assertEqual(package, 62.0)
        self.assertEqual(cores, {(0, '0'): 60.0, (0, '1'): 58.0})

    def test_no_sensor_reads_as_none(self):
        self.sensor(0, 'nvme', {1: ('Composite', 41850)})
        self.assertEqual(cpu.temperatures(), (None, {}, []))


if __name__ == '__main__':
    unittest.main()
