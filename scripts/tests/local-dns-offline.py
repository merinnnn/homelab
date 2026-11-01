#!/usr/bin/env python3
"""Check that adding project records cannot silently replace existing DNS."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
path = Path(__file__).resolve().parents[1] / 'deploy/install-local-dns.py'
spec = importlib.util.spec_from_file_location('local_dns', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Records(unittest.TestCase):
    def test_preserves_unrelated_and_multi_alias_records(self):
        old = ['192.168.1.40 nas.home.arpa files.home.arpa', '# existing comment']
        self.assertEqual(module.merge_records(old, {'uptime.home.arpa': '192.168.1.58'}),
                         old + ['192.168.1.58 uptime.home.arpa'])

    def test_repeat_is_idempotent(self):
        data = {'uptime.home.arpa': '192.168.1.58'}
        once = module.merge_records([], data)
        self.assertEqual(module.merge_records(once, data), once)

    def test_existing_alias_is_case_insensitive(self):
        old = ['192.168.1.58 other.home.arpa UPTIME.HOME.ARPA.']
        self.assertEqual(module.merge_records(old, {'uptime.home.arpa': '192.168.1.58'}), old)

    def test_conflicting_alias_is_refused(self):
        with self.assertRaises(ValueError):
            module.merge_records(['192.168.1.99 UPTIME.HOME.ARPA.'], {'uptime.home.arpa': '192.168.1.58'})

    def test_external_names_are_refused(self):
        for name in ['example.com', 'home.arpa', 'bad name.home.arpa', '-bad.home.arpa']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                module.merge_records([], {name: '192.168.1.58'})

    def test_outside_and_nonhost_addresses_are_refused(self):
        for address in ['1.1.1.1', '192.168.1.0', '192.168.1.255', '192.168.1.999']:
            with self.subTest(address=address), self.assertRaises(ValueError):
                module.merge_records([], {'uptime.home.arpa': address})


if __name__ == '__main__':
    unittest.main()
