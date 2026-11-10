#!/usr/bin/env bash

set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd -- "$script_directory/../.." && pwd)"
frontend_directory="$repository_directory/../frontend"
test_directory="$(mktemp -d)"
trap 'rm -rf -- "$test_directory"' EXIT
export ANSIBLE_CONFIG="$repository_directory/ansible.cfg"
export ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote

# Read the real deployment assertion and variable definitions through Ansible's
# YAML support instead of duplicating the guard or adding a YAML parser.
cat >"$test_directory/render.yml.j2" <<'YAML'
{% set definition = (lookup('ansible.builtin.file', repository_directory ~ '/shared/playbooks/deploy.yml') | from_yaml)[0] %}
{% raw %}
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    deployment: "{{ lookup('ansible.builtin.file', repository_directory ~ '/shared/playbooks/deploy.yml') | from_yaml }}"
    morrowpal_web_client_build: {% endraw %}{{ definition.vars.morrowpal_web_client_build | to_json }}{% raw %}
    morrowpal_web_firebase_config: {% endraw %}{{ definition.vars.morrowpal_web_firebase_config | to_json }}{% raw %}
  tasks:
    - name: Run the actual deployment's public configuration assertion
      ansible.builtin.assert:
        that: "{{ deployment[0].pre_tasks[0]['ansible.builtin.assert'].that }}"
        fail_msg: "{{ deployment[0].pre_tasks[0]['ansible.builtin.assert'].fail_msg }}"
    - name: Render the actual deployment's public runtime template
      ansible.builtin.template:
        src: "{{ repository_directory }}/shared/runtime/app/runtime-config.js.j2"
        dest: "{{ runtime_destination }}"
        mode: "0600"
{% endraw %}
YAML

if ! ansible localhost -i localhost, --connection local \
    --module-name ansible.builtin.template \
    --args "src=$test_directory/render.yml.j2 dest=$test_directory/render.yml mode=0600" \
    -e "repository_directory=$repository_directory" \
    >"$test_directory/template.log" 2>&1; then
    cat "$test_directory/template.log" >&2
    exit 1
fi

for environment in prod staging; do
    runtime_file="$test_directory/$environment.js"
    arguments=(ansible-playbook -i localhost, "$test_directory/render.yml"
        -e "@$repository_directory/environments/$environment/vars.yml"
        -e "repository_directory=$repository_directory"
        -e "morrowpal_frontend_directory=$frontend_directory"
        -e "runtime_destination=$runtime_file")
    if ! "${arguments[@]}" >"$test_directory/render.log" 2>&1; then
        cat "$test_directory/render.log" >&2
        exit 1
    fi

    node - "$runtime_file" "$frontend_directory" "$environment" <<'JS'
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const [runtimeFile, frontend, environment] = process.argv.slice(2);
const runtime = fs.readFileSync(runtimeFile, 'utf8');
const read = name => JSON.parse(fs.readFileSync(
  `${frontend}/config/firebase/${environment}/${name}.json`, 'utf8'));
let options;
const context = {firebase: {
  initializeApp(value) { options = value; }, messaging() {}
}};
context.self = context;
context.importScripts = (...urls) => {
  if (urls[0] === 'runtime-config.js') vm.runInNewContext(runtime, context);
};
vm.runInNewContext(fs.readFileSync(`${frontend}/web/firebase-messaging-sw.js`, 'utf8'), context);
const configuration = JSON.parse(context.MORROWPAL_RUNTIME_CONFIG);
assert.strictEqual(configuration.environment, environment);
assert.strictEqual(configuration.apiBaseUrl, read('build').apiBaseUrl);
assert.deepStrictEqual(configuration.firebase, read('web'));
assert.deepStrictEqual(JSON.parse(JSON.stringify(options)), configuration.firebase);
JS

    if "${arguments[@]}" \
        -e morrowpal_firebase_project_id=wrong-environment-project \
        -e "runtime_destination=$test_directory/rejected.js" \
        >"$test_directory/rejected.log" 2>&1; then
        printf 'Error: Deployment accepted a Firebase mismatch.\n' >&2
        exit 1
    fi
    grep -Fq 'Public web client configuration does not match' "$test_directory/rejected.log"
    [[ ! -e "$test_directory/rejected.js" ]]
done

printf 'Public web runtime configuration and environment mismatch validation passed.\n'
