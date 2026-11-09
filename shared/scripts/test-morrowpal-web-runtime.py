#!/usr/bin/env python3
"""Exercise the deployment's real public-config assertion and template locally."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[2]
FRONTEND = ROOT.parent / "frontend"
DEPLOY = yaml.safe_load((ROOT / "shared/playbooks/deploy.yml").read_text())[0]


def render(directory, environment, mismatch=False):
    variables = yaml.safe_load(
        (ROOT / f"environments/{environment}/vars.yml").read_text()
    )
    variables["morrowpal_frontend_directory"] = str(FRONTEND)
    for key in ("morrowpal_web_client_build", "morrowpal_web_firebase_config"):
        variables[key] = DEPLOY["vars"][key]
    if mismatch:
        variables["morrowpal_firebase_project_id"] = "wrong-environment-project"
    destination = directory / f"{environment}-{mismatch}.js"
    playbook = directory / "render.yml"
    playbook.write_text(yaml.safe_dump([{
        "hosts": "localhost",
        "connection": "local",
        "gather_facts": False,
        "vars": variables,
        "tasks": [DEPLOY["pre_tasks"][0], {
            "ansible.builtin.template": {
                "src": str(ROOT / "shared/runtime/app/runtime-config.js.j2"),
                "dest": str(destination),
            },
        }],
    }]))
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", str(playbook)],
        env={**os.environ, "ANSIBLE_CONFIG": str(ROOT / "ansible.cfg"),
             "ANSIBLE_REMOTE_TEMP": "/tmp/morrowpal-ansible-remote"},
        capture_output=True, text=True,
    )
    if mismatch:
        assert result.returncode != 0, "Deployment accepted a Firebase mismatch"
        assert "Public web client configuration does not match" in result.stdout
        assert not destination.exists(), "Mismatch wrote runtime configuration"
        return
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(destination.read_text().split(" = ", 1)[1].strip().removesuffix(";"))
    configuration = json.loads(payload)
    assert configuration["environment"] == environment
    assert configuration["apiBaseUrl"] == variables["morrowpal_public_urls"]["api"]
    assert configuration["firebase"] == json.loads(
        (FRONTEND / f"config/firebase/{environment}/web.json").read_text()
    )
    # Run the actual worker with its external SDK mocked. Both consumers must
    # receive the deployment's configuration, with no compiled environment.
    subprocess.run(["node", "-e", r"""
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const runtime = fs.readFileSync(process.argv[1], 'utf8');
const worker = fs.readFileSync(process.argv[2], 'utf8');
let options;
const context = {firebase: {
  initializeApp(value) { options = value; }, messaging() {}
}};
context.self = context;
context.importScripts = (...urls) => {
  if (urls[0] === 'runtime-config.js') vm.runInNewContext(runtime, context);
};
vm.runInNewContext(worker, context);
assert.strictEqual(options.projectId,
  JSON.parse(context.MORROWPAL_RUNTIME_CONFIG).firebase.projectId);
""", str(destination), str(FRONTEND / "web/firebase-messaging-sw.js")], check=True)


with tempfile.TemporaryDirectory(prefix="morrowpal-web-runtime-") as temporary:
    for selected_environment in ("prod", "staging"):
        render(Path(temporary), selected_environment)
        render(Path(temporary), selected_environment, mismatch=True)
print("Public web runtime configuration and environment mismatch validation passed.")
