import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]


class TestWindowsPortablePackage(unittest.TestCase):
    def test_build_script_generates_portable_package_entrypoints(self):
        script_path = ROOT_DIR / "scripts" / "build-windows-portable.ps1"
        self.assertTrue(script_path.is_file())

        script = script_path.read_text(encoding="utf-8")

        self.assertIn("Set-StrictMode -Version Latest", script)
        self.assertIn("uv sync --frozen", script)
        self.assertIn("start.bat", script)
        self.assertIn("update.bat", script)
        self.assertIn(".venv\\Scripts\\streamlit.exe", script)
        self.assertIn("Compress-Archive", script)

    def test_readme_documents_windows_package_generation(self):
        readme = (ROOT_DIR / "README.md").read_text(encoding="utf-8")

        self.assertIn("生成 Windows 一键启动包", readme)
        self.assertIn("scripts\\build-windows-portable.ps1", readme)
        self.assertIn("MoneyPrinterTurbo-windows-portable.zip", readme)


if __name__ == "__main__":
    unittest.main()
