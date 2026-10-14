"""Test package.

Imported by pytest before conftest.py, so this runs before any application module.
app.main builds the app (and reads settings) when it is imported, which happens
while tests are being collected, before any fixture can isolate them. Remove the
developer's Azure configuration here, for the whole test session, so a shell
variable or backend/.env can never configure or break the tests. The autouse
fixture in conftest.py repeats this per test for values set during a test.
"""

import os

from app.config.settings import Settings

for _name in [
    name for name in os.environ if name.startswith(("JARVIS_FOUNDRY_", "JARVIS_SPEECH_"))
]:
    del os.environ[_name]

Settings.model_config["env_file"] = None
