import fs from 'node:fs';
import assert from 'node:assert/strict';
const [recordPath,productionPath,currentPath]=process.argv.slice(2);
const record=JSON.parse(fs.readFileSync(recordPath,'utf8'));
const production=JSON.parse(fs.readFileSync(productionPath,'utf8'));
const current=JSON.parse(fs.readFileSync(currentPath,'utf8'));
assert.equal(record.environment,'staging');
assert([record.original.instanceId,record.candidate.instanceId].includes(current.instanceId),'Unexpected physical host identity');
const isOriginal=current.instanceId===record.original.instanceId;
const osBaseline=isOriginal?JSON.parse(fs.readFileSync(recordPath+'.original-host-baseline.json','utf8')):production;
for(const key of ['kernel','os','docker','compose']) assert.equal(current[key],osBaseline[key],`${key} differs from the selected host baseline`);
assert.equal(current.filesystem,'xfs');
assert.equal(current.filesystemUuid,record.data.filesystemUuid);
assert.equal(current.containers.length,8);
const registry=`${record.accountId}.dkr.ecr.${record.region}.amazonaws.com/morrowpal/staging/`;
for(const [component,tag,digest,count] of [
 ['backend-api',record.releases.backend.tag,record.releases.backend.apiDigest,2],
 ['backend-job',record.releases.backend.tag,record.releases.backend.jobDigest,2],
 ['app',record.releases.app.tag,record.releases.app.digest,1],
 ['website',record.releases.website.tag,record.releases.website.digest,1]]) {
 const uri=registry+component;
 const containers=current.containers.filter(container=>container.image.startsWith(uri+':'));
 assert.equal(containers.length,count,`${component} container count`);
 for(const container of containers) {
  assert.equal(container.state,'running');
  assert.equal(container.image,`${uri}:${tag}`);
  assert(current.images.find(image=>image.imageId===container.imageId)?.repoDigests.includes(`${uri}@${digest}`),`${component} running manifest digest`);
 }
}
for(const dependency of ['mysql','envoy']) {
 const suffix=`-${dependency}-1`;
 const expected=production.containers.find(container=>container.name.endsWith(suffix));
 const actual=current.containers.find(container=>container.name.endsWith(suffix));
 assert(expected&&actual,`Missing ${dependency}`);
 assert.match(expected.imageId,/^sha256:[0-9a-f]{64}$/);
 assert.equal(actual.imageId,expected.imageId,`${dependency} image content differs from production`);
}
console.log(JSON.stringify({instanceId:current.instanceId,osBaseline:isOriginal?'original-staging':'production',baseOsKernelAndEnginesMatchBaseline:true,retainedFilesystemMatches:true,allFourRunningManifestDigestsMatchRecord:true,mysqlAndEnvoyMatchProduction:true,containerCount:8},null,2));
