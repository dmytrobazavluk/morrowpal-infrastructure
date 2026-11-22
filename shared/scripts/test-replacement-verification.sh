#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
node --input-type=module - "$work" <<'NODE'
import fs from 'node:fs';
const directory=process.argv[2],digest=c=>`sha256:${c.repeat(64)}`;
const record={environment:'staging',original:{instanceId:'i-12345678'},candidate:{instanceId:'i-23456789'},accountId:'123456789012',region:'us-east-1',data:{filesystemUuid:'retained-uuid'},releases:{backend:{tag:'build-1-abcdef0',apiDigest:digest('a'),jobDigest:digest('b')},app:{tag:'build-2-abcdef0',digest:digest('c')},website:{tag:'build-3-abcdef0',digest:digest('d')}}};
const current={instanceId:'i-23456789',kernel:'6.1.test',os:'al2023.test',docker:'25.test',compose:'5.test',filesystem:'xfs',filesystemUuid:'retained-uuid',containers:[],images:[]};
for(const [component,tag,dig,count] of [['backend-api',record.releases.backend.tag,digest('a'),2],['backend-job',record.releases.backend.tag,digest('b'),2],['app',record.releases.app.tag,digest('c'),1],['website',record.releases.website.tag,digest('d'),1]]) {
 const uri=`123456789012.dkr.ecr.us-east-1.amazonaws.com/morrowpal/staging/${component}`;
 const imageId=`image-${component}`;
 for(let i=0;i<count;i++) current.containers.push({name:`/morrowpal-${component}-${i+1}`,state:'running',image:`${uri}:${tag}`,imageId});
 current.images.push({imageId,repoDigests:[`${uri}@${dig}`]});
}
for(const dependency of ['mysql','envoy']) current.containers.push({name:`/morrowpal-${dependency}-1`,image:`${dependency}:pinned`,imageId:digest(dependency==='mysql'?'e':'f'),state:'running'});
const production=structuredClone(current);
production.containers[6].image='mysql:8.4';
for(const [name,value] of [['record',record],['current',current],['production',production]]) fs.writeFileSync(`${directory}/${name}.json`,JSON.stringify(value));
const original=structuredClone(current); original.instanceId=record.original.instanceId; original.kernel='6.18.original';
fs.writeFileSync(`${directory}/original.json`,JSON.stringify(original));
fs.writeFileSync(`${directory}/record.json.original-host-baseline.json`,JSON.stringify(original));
NODE
node "$directory/verify-replacement-host-metadata.mjs" "$work/record.json" "$work/production.json" "$work/current.json" >"$work/output"
node "$directory/verify-replacement-host-metadata.mjs" "$work/record.json" "$work/production.json" "$work/original.json" >"$work/output"
for mutation in '.kernel="6.18.wrong"' '.filesystemUuid="wrong"' '.containers[0].state="exited"' \
    '.images[0].repoDigests=[]' '.containers[4].image="wrong-tag"' '.containers[6].imageId="sha256:wrong"' 'del(.containers[7])' '.instanceId="i-unknown"'; do
    jq "$mutation" "$work/current.json" >"$work/invalid.json"
    if node "$directory/verify-replacement-host-metadata.mjs" "$work/record.json" "$work/production.json" "$work/invalid.json" >"$work/output" 2>&1; then
        printf 'Accepted invalid replacement metadata: %s\n' "$mutation" >&2; exit 1
    fi
done
printf 'Replacement runtime verification passed, rejecting OS/kernel, storage UUID, running-state, manifest/tag and dependency mismatches.\n'
