#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd -- "$script_directory/../.." && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf -- "$test_directory"' EXIT
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
export ANSIBLE_CONFIG="$repository_directory/ansible.cfg"
export ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote

# Parse through the installed Ansible YAML loader; no extra parser dependency.
cat >"$test_directory/convert.yml" <<'YAML'
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.copy:
        content: "{{ lookup('file', storage_source) | from_yaml | to_nice_json }}"
        dest: "{{ storage_json }}"
        mode: '0600'
YAML
ansible-playbook "$test_directory/convert.yml" -i localhost, --connection local \
    -e "$(jq -n --arg source "$repository_directory/shared/playbooks/prepare-storage.yml" \
        --arg json "$test_directory/source.json" '{storage_source:$source,storage_json:$json}')" \
    >"$test_directory/convert.log" 2>&1 || { cat "$test_directory/convert.log"; exit 1; }

# Run the real input checks and filesystem tasks on localhost with fake commands.
# No dnf, device discovery, mount, file permissions, or swap tasks are included.
node - "$test_directory" <<'JS'
const fs=require('fs');const dir=process.argv[2];
const source=JSON.parse(fs.readFileSync(`${dir}/source.json`))[0];
const names=['Inspect the data volume filesystem','Require an existing XFS filesystem for recovery',
 'Create the XFS filesystem on the empty data volume','Require XFS on the data volume',
 'Read the data volume UUID','Verify the retained filesystem UUID before mounting'];
const tasks=source.tasks.filter(t=>names.includes(t.name));
if(tasks.length!==names.length || tasks.some(t=>!t['ansible.builtin.command']&&!t['ansible.builtin.assert']))throw Error('Unexpected storage test task selection');
if(source.pre_tasks.some(t=>!t['ansible.builtin.assert']))throw Error('Only input assertions may run as test pre-tasks');
for(const task of tasks){
 const argv=task['ansible.builtin.command']?.argv;
 if(argv && (!['blkid','mkfs.xfs'].includes(argv[0]) || argv.at(-1)!=='{{ morrowpal_mysql_device_result.stdout }}'))throw Error('Disk command cannot be safely mocked');
}
fs.mkdirSync(`${dir}/bin`);
const uuid='11111111-2222-3333-4444-555555555555';
const cases=[
 {name:'recover',fs:'xfs',flag:true,uuid,ok:true},
 {name:'recover-string',fs:'xfs',flag:'true',uuid,ok:true},
 {name:'recover-empty',fs:'empty',flag:true,uuid,error:'Recovery requires an existing XFS'},
 {name:'recover-ext4',fs:'ext4',flag:true,uuid,error:'Recovery requires an existing XFS'},
 {name:'recover-wrong-uuid',fs:'xfs',flag:true,uuid:'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',error:'Retained filesystem UUID does not match'},
 {name:'recover-no-uuid',fs:'xfs',flag:true,error:'Recovery requires existing-filesystem mode'},
 {name:'recover-invalid-uuid',fs:'xfs',flag:true,uuid:'invalid',error:'Recovery requires existing-filesystem mode'},
 {name:'uuid-without-mode',fs:'empty',uuid,error:'Recovery requires existing-filesystem mode'},
 {name:'typo-mode',fs:'empty',flag:'treu',uuid,error:'must be true or false'},
 {name:'fresh-empty',fs:'empty',ok:true,format:true},
 {name:'fresh-false',fs:'empty',flag:false,ok:true,format:true},
 {name:'fresh-string-false',fs:'empty',flag:'false',ok:true,format:true},
 {name:'existing-xfs',fs:'xfs',ok:true},
 {name:'existing-ext4',fs:'ext4',error:'unexpected filesystem'},
 {name:'read-error',fs:'read-error',flag:true,uuid,error:'Inspect the data volume filesystem'},
 {name:'uuid-read-error',fs:'xfs',flag:true,uuid,uuidError:true,error:'Read the data volume UUID'}
];
fs.writeFileSync(`${dir}/cases.json`,JSON.stringify(cases));
for(const c of cases){
 const caseDir=`${dir}/${c.name}`;fs.mkdirSync(caseDir);
 fs.writeFileSync(`${caseDir}/filesystem`,c.fs);
 fs.writeFileSync(`${caseDir}/uuid`,c.uuidError?'read-error':uuid);
 const inputs={};if('flag'in c)inputs.morrowpal_require_existing_mysql_filesystem=c.flag;
 if('uuid'in c)inputs.morrowpal_expected_mysql_filesystem_uuid=c.uuid;
 fs.writeFileSync(`${caseDir}/inputs.json`,JSON.stringify(inputs));
 const play={hosts:'localhost',connection:'local',gather_facts:false,
  environment:{PATH:`${dir}/bin:${process.env.PATH}`,STORAGE_TEST_DIR:caseDir},
  vars:{morrowpal_mysql_volume_id:'vol-0123456789abcdef0',morrowpal_mysql_device_result:{stdout:'/dev/nvme999n1'}},
  pre_tasks:source.pre_tasks,tasks:[...tasks,{name:'Reached mount boundary',
   'ansible.builtin.file':{path:`${caseDir}/mount-boundary`,state:'touch'}}]};
 fs.writeFileSync(`${caseDir}/play.json`,JSON.stringify([play]));
}
JS
cat >"$test_directory/bin/blkid" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$5" == /dev/nvme999n1 ]] || exit 90
printf 'blkid %s\n' "$4" >>"$STORAGE_TEST_DIR/calls"
if [[ "$4" == TYPE ]]; then
    filesystem=$(cat "$STORAGE_TEST_DIR/filesystem")
    case "$filesystem" in empty) exit 2 ;; read-error) exit 1 ;; *) printf '%s\n' "$filesystem" ;; esac
else
    uuid=$(cat "$STORAGE_TEST_DIR/uuid")
    [[ "$uuid" != read-error ]] || exit 2
    printf '%s\n' "$uuid"
fi
SH
cat >"$test_directory/bin/mkfs.xfs" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == /dev/nvme999n1 ]] || exit 90
printf 'mkfs\n' >>"$STORAGE_TEST_DIR/calls"
printf 'xfs\n' >"$STORAGE_TEST_DIR/filesystem"
SH
chmod 0700 "$test_directory/bin/blkid" "$test_directory/bin/mkfs.xfs"
while IFS= read -r name; do
    case_directory="$test_directory/$name"
    succeeded=false
    if ansible-playbook "$case_directory/play.json" -i localhost, --connection local \
        -e "@$case_directory/inputs.json" >"$case_directory/output.log" 2>&1; then succeeded=true; fi
    expected=$(jq -r --arg name "$name" '.[] | select(.name==$name) | .ok // false' "$test_directory/cases.json")
    if [[ "$succeeded" != "$expected" ]]; then cat "$case_directory/output.log"; fail "Unexpected outcome: $name"; fi
    if [[ "$succeeded" == false ]]; then
        error=$(jq -r --arg name "$name" '.[] | select(.name==$name) | .error' "$test_directory/cases.json")
        grep -Fq "$error" "$case_directory/output.log" || { cat "$case_directory/output.log"; fail "Wrong failure: $name"; }
        [[ ! -e "$case_directory/mount-boundary" ]] || fail "Failed recovery reached mount: $name"
    else
        [[ -e "$case_directory/mount-boundary" ]] || fail "Valid filesystem blocked: $name"
    fi
    formatted=false
    if [[ -f "$case_directory/calls" ]] && grep -qx mkfs "$case_directory/calls"; then formatted=true; fi
    expected_format=$(jq -r --arg name "$name" '.[] | select(.name==$name) | .format // false' "$test_directory/cases.json")
    [[ "$formatted" == "$expected_format" ]] || fail "Unexpected formatting: $name"
done < <(jq -r '.[].name' "$test_directory/cases.json")
printf 'Storage recovery checks passed across 16 cases; all disk commands were mocked.\n'
