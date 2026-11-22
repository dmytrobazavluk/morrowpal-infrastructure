// Offline stateful AWS substitute used only by test-staging-replacement.sh.
import fs from 'node:fs';
const root=process.env.REPLACEMENT_TEST_ROOT;
if(!root) throw Error('This fixture requires an isolated test root');
const file=`${root}/state.json`, state=JSON.parse(fs.readFileSync(file,'utf8'));
const record=JSON.parse(fs.readFileSync(`${root}/record.json`,'utf8'));
const args=process.argv.slice(2), option=k=>args[args.indexOf(k)+1];
const account=record.accountId,region=record.region,prefix='morrowpal-staging';
const host=id=>id===record.original.instanceId?'original':id===record.candidate.instanceId?'candidate':null;
const arn=name=>`arn:aws:cloudformation:${region}:${account}:stack/${name}/fixture`;
const role=`arn:aws:iam::${account}:role/staging-stop`;
const output=v=>process.stdout.write(JSON.stringify(v)+'\n');
const save=()=>fs.writeFileSync(file,JSON.stringify(state));
fs.appendFileSync(`${root}/calls`,args.join(' ')+'\n');
if(args[0]==='prepare') {
 const [,env,kind,name,...flags]=args;
 if(env!=='staging') throw Error('Foreign environment');
 const vars=fs.readFileSync(`${root}/environments/staging/vars.yml`,'utf8');
 const active=vars.match(/morrowpal_ec2_stack_name: (.+)/)[1];
 const target=active===record.original.stackName?'original':'candidate';
 state.pending={kind,name,target,disabled:flags.includes('--disable-auto-stop'),detach:flags.includes('--detach-mysql-volume')};
 save();process.exit(0);
}
if(option('--region')!==region) throw Error('Unexpected region');
switch(`${args[0]} ${args[1]}`) {
case 'sts get-caller-identity': process.stdout.write(state.wrongAccount?'999999999999\n':account+'\n');break;
case 'cloudformation describe-stacks': {
 const name=option('--stack-name');let parameters={},outputs={};
 if(name===`${prefix}-mysql-storage`) parameters={InstanceId:record[state.storage==='detached'?state.storageParameter:state.storage].instanceId,AttachVolume:state.storage==='detached'?'false':'true'},outputs={VolumeId:record.data.volumeId,DeviceName:'/dev/sdf'};
 else if(name===`${prefix}-public-ip`) parameters={InstanceId:record[state.ip].instanceId};
 else if(name===`${prefix}-auto-stop`) {
  parameters={InstanceId:record[state.shutdown].instanceId,ScheduleState:state.scheduleState};
  outputs={ExecutionRoleArn:role,ScheduleGroupName:record.shutdown.groupName,ScheduleName:record.shutdown.scheduleName};
 } else throw Error('Unexpected stack');
 output({Stacks:[{StackId:arn(name),StackStatus:state.stackStatus||'UPDATE_COMPLETE',Parameters:Object.entries(parameters).map(([ParameterKey,ParameterValue])=>({ParameterKey,ParameterValue})),Outputs:Object.entries(outputs).map(([OutputKey,OutputValue])=>({OutputKey,OutputValue}))}]});break;
}
case 'cloudformation wait': break;
case 'cloudformation describe-change-set': {
 const p=state.pending,op=p.kind==='mysql-storage'?(p.detach?'detach':'attach'):p.kind;
 let resource=op==='detach'||op==='attach'?{Action:op==='detach'?'Remove':'Add',LogicalResourceId:'MysqlDataVolumeAttachment',ResourceType:'AWS::EC2::VolumeAttachment'}:
  op==='public-ip'?{Action:'Modify',LogicalResourceId:'ProductionElasticIpAssociation',ResourceType:'AWS::EC2::EIPAssociation',Replacement:'True'}:
  op==='candidate'?{Action:'Add',LogicalResourceId:'ProductionInstance',ResourceType:'AWS::EC2::Instance'}:
  {Action:'Modify',LogicalResourceId:'NightlyStop',ResourceType:'AWS::Scheduler::Schedule',Replacement:'False'};
 if(state.unsafeChange) resource={Action:'Modify',LogicalResourceId:'MysqlDataVolume',ResourceType:'AWS::EC2::Volume',Replacement:'True'};
 output({StackId:arn(option('--stack-name')),ChangeSetName:option('--change-set-name'),Status:'CREATE_COMPLETE',ExecutionStatus:'AVAILABLE',Parameters:[{ParameterKey:'Environment',ParameterValue:state.foreignEnvironment?'prod':'staging'}],Changes:[{Type:'Resource',ResourceChange:resource}]});break;
}
case 'cloudformation execute-change-set': {
 const p=state.pending,op=p.kind==='mysql-storage'?(p.detach?'detach':'attach'):p.kind;
 if(state.failOperation===op) process.exit(96);
 if(op==='detach') {state.storage='detached';state.storageParameter=p.target;}
 else if(op==='attach') state.storage=p.target;
 else if(op==='public-ip') state.ip=p.target;
 else if(op==='auto-stop') {state.shutdown=p.target;state.scheduleState=p.disabled?'DISABLED':'ENABLED';}
 state.executed.push(op);save();break;
}
case 'ec2 describe-instances': output({Reservations:[{OwnerId:account,Instances:['original','candidate'].map(h=>({InstanceId:record[h].instanceId,State:{Name:state.runningHost===h?'running':'stopped'}}))}]});break;
case 'ec2 create-snapshot':
 if(option('--volume-id')!==record.data.volumeId) throw Error('Wrong snapshot source');
 state.snapshots++;save();output({SnapshotId:'snap-45678901'});break;
case 'ec2 create-volume': output({VolumeId:record.data.volumeId});break;
case 'ec2 wait': break;
case 'scheduler get-schedule': output({Arn:`arn:aws:scheduler:${region}:${account}:schedule/${record.shutdown.groupName}/${record.shutdown.scheduleName}`,GroupName:record.shutdown.groupName,Name:record.shutdown.scheduleName,State:state.scheduleState,ScheduleExpression:state.badCron?'rate(1 minute)':'cron(0 1 * * ? *)',ScheduleExpressionTimezone:'America/Chicago',FlexibleTimeWindow:{Mode:'OFF'},Target:{Arn:'arn:aws:scheduler:::aws-sdk:ec2:stopInstances',RoleArn:role,Input:JSON.stringify({InstanceIds:[record[state.shutdown].instanceId],Force:!!state.force}),RetryPolicy:{MaximumEventAgeInSeconds:300,MaximumRetryAttempts:2}}});break;
case 'iam get-role': output({Role:{Arn:role,AssumeRolePolicyDocument:{Version:'2012-10-17',Statement:[{Effect:'Allow',Principal:{Service:'scheduler.amazonaws.com'},Action:'sts:AssumeRole',Condition:{StringEquals:{'aws:SourceAccount':state.badTrust?'999999999999':account},ArnEquals:{'aws:SourceArn':`arn:aws:scheduler:${region}:${account}:schedule-group/${record.shutdown.groupName}`}}}]}}});break;
case 'iam list-role-policies':output({PolicyNames:state.extraPolicy?['StopStagingInstance','Extra']:['StopStagingInstance']});break;
case 'iam list-attached-role-policies':output({AttachedPolicies:state.managedPolicy?[{PolicyArn:'foreign'}]:[]});break;
case 'iam get-role-policy':output({PolicyDocument:{Version:'2012-10-17',Statement:[{Effect:'Allow',Action:'ec2:StopInstances',Resource:state.wildcard?'*':`arn:aws:ec2:${region}:${account}:instance/${record[state.shutdown].instanceId}`,Condition:{StringEquals:{'ec2:ResourceTag/Environment':state.badTag?'prod':'staging','ec2:ResourceTag/Application':'morrowpal'}}}]}});break;
default: throw Error(`Unexpected AWS call: ${args[0]} ${args[1]}`);
}
