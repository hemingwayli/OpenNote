"""验证环境、本机配置与可分发工具链清单的边界。"""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('opennote_toolchain', ROOT / 'tools/toolchain.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ToolchainTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'tools').mkdir()
        (self.root / 'tools/toolchain-lock.json').write_text(
            json.dumps({'sdkPath': '.local/toolchains/flutter'}), encoding='utf-8')
        self.environment = patch.dict(os.environ, {'OPENNOTE_FLUTTER_ROOT': ''})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_relative_default_is_anchored_to_project(self):
        self.assertEqual(module.resolve_flutter_sdk(self.root), (self.root / '.local/toolchains/flutter').resolve())

    def test_local_selection_is_used_without_changing_public_lock(self):
        selected = self.root / 'external-sdk'
        module.save_toolchain({'version': 'fixed', 'sha256': 'fixed-hash'}, selected, self.root)
        self.assertEqual(module.resolve_flutter_sdk(self.root), selected.resolve())
        lock = json.loads((self.root / 'tools/toolchain-lock.json').read_text(encoding='utf-8'))
        self.assertEqual(lock['sdkPath'], '.local/toolchains/flutter')
        self.assertNotIn(str(selected), json.dumps(lock))
        self.assertEqual(lock['flutter']['sha256'], 'fixed-hash')

    def test_environment_overrides_local_selection(self):
        module.save_toolchain({'version': 'fixed'}, self.root / 'local-sdk', self.root)
        with patch.dict(os.environ, {'OPENNOTE_FLUTTER_ROOT': str(self.root / 'environment-sdk')}):
            self.assertEqual(module.resolve_flutter_sdk(self.root), (self.root / 'environment-sdk').resolve())

    def test_invalid_local_path_is_rejected(self):
        local = self.root / '.local'
        local.mkdir()
        (local / 'toolchain.json').write_text('{"sdkPath": 123}', encoding='utf-8')
        with self.assertRaises(ValueError):
            module.resolve_flutter_sdk(self.root)


if __name__ == '__main__':
    unittest.main()
