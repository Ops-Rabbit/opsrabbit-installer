# Send AWS Spot notifications to private OpsRabbit

Use EventBridge to POST Spot warnings to OpsRabbit's existing webhook. OpsRabbit stays on private EC2; no Lambda or VM watcher is needed. EventBridge uses a private API Destination through VPC Lattice.

| Where the Spot instance runs | Delivery path |
| --- | --- |
| Same account as OpsRabbit | Default EventBridge bus → private API Destination → OpsRabbit |
| Different account | Source default bus → OpsRabbit account default bus → private API Destination → OpsRabbit |

The examples use the **same AWS Region** in both accounts and the standard AWS partition. Repeat the source-account configuration in each account/Region that contains Spot instances; other Region layouts need an explicitly designed cross-Region forwarding path. EventBridge, VPC Lattice and the managed Connection secret can incur AWS charges.

## 1 Prepare OpsRabbit and private connectivity

Do this once in the account hosting OpsRabbit.

1. Enable HTTPS on the existing Nginx using the post-install commands from [the installer guide](../README.md#post-install-https-with-the-existing-nginx). Use port 443 and a publicly trusted certificate matching a hostname you own, such as `opsrabbit.example.com`. Certificate DNS validation does not require a public EC2 IP. Use a private Route 53 record pointing that hostname to the EC2 private IP.
2. In OpsRabbit, create a **Webhook Inbound**, configure its Webhook Token and receiving agent, and copy the exact instance URL, for example `https://opsrabbit.example.com/webhooks/inbound/aws-spot`. Use that URL rather than the backend's loopback port.
3. In the VPC Lattice console, create a **resource gateway** in OpsRabbit's VPC with appropriate subnets. Set **Resource config DNS resolution** to `IN_VPC` so it can resolve the private Route 53 record. Enable VPC DNS support and associate the private hosted zone with this VPC.
4. Create a **SINGLE resource configuration** for the DNS name `opsrabbit.example.com`, TCP port 443, using that gateway. Copy its resource configuration ARN. Use a current AWS CLI/console and confirm this feature is available in your Region.
5. Allow gateway traffic to the instance: the gateway security group needs outbound TCP 443 to OpsRabbit, and the EC2 security group needs inbound TCP 443 from the gateway security group. Preserve any separate user access rules. Check subnet routes and network ACLs too.

A private IP alone, an ordinary public API Destination, or VPC peering alone does not give EventBridge this connectivity. The public-domain hostname and publicly trusted certificate requirement also applies to private API Destinations. [AWS private connections](https://docs.aws.amazon.com/eventbridge/latest/userguide/connection-private.html), [HTTPS requirements](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-api-destinations.html), [private DNS resolution](https://docs.aws.amazon.com/cli/latest/reference/vpc-lattice/create-resource-gateway.html).

## 2 Configure delivery in the OpsRabbit account

Use a Bash terminal with current AWS CLI v2 and `jq`. The AWS profile must be allowed to create EventBridge resources, create/pass the scoped IAM role, create Connection secrets/service-linked roles, and associate the VPC Lattice resource through EventBridge. These are infrastructure-administrator permissions, separate from the narrowly scoped runtime role created below.

Edit the first four values. Run this block once with unused resource names. It creates resources; it is not a repeatable update/cleanup script. Disable shell tracing before handling the token. Generated files live in a private temporary directory; delete that directory when finished.

```bash
set -euo pipefail
set +x
export AWS_PAGER=''
OPS_PROFILE=opsrabbit-admin
REGION=us-east-1
WEBHOOK_URL=https://opsrabbit.example.com/webhooks/inbound/aws-spot
RESOURCE_ARN=arn:aws:vpc-lattice:us-east-1:111111111111:resourceconfiguration/rcfg-REPLACE_ME

OPS_ACCOUNT=$(aws --profile "$OPS_PROFILE" sts get-caller-identity --query Account --output text)
opsaws() { aws --profile "$OPS_PROFILE" --region "$REGION" "$@"; }
umask 077
WORK_DIR=$(mktemp -d)
read -r -s -p 'OpsRabbit Webhook Token: ' OPSRABBIT_WEBHOOK_TOKEN
printf '\n'
export OPSRABBIT_WEBHOOK_TOKEN
jq -n '{ApiKeyAuthParameters:{ApiKeyName:"x-opsrabbit-webhook-token",ApiKeyValue:env.OPSRABBIT_WEBHOOK_TOKEN}}' > "$WORK_DIR/auth.json"
unset OPSRABBIT_WEBHOOK_TOKEN

CONNECTION_ARN=$(opsaws events create-connection \
  --name opsrabbit-spot --authorization-type API_KEY \
  --auth-parameters "file://$WORK_DIR/auth.json" \
  --invocation-connectivity-parameters "ResourceParameters={ResourceConfigurationArn=$RESOURCE_ARN}" \
  --query ConnectionArn --output text)
rm "$WORK_DIR/auth.json"

# Check until ConnectionState is AUTHORIZED before continuing.
opsaws events describe-connection --name opsrabbit-spot \
  --query '{State:ConnectionState,Reason:StateReason}'
```

If the state is not `AUTHORIZED`, fix the reported connectivity/permission problem before running the next block. AWS manages the Connection secret; do not put the token in the webhook URL or payload.

Continue in the same terminal:

```bash
DEST_ARN=$(opsaws events create-api-destination \
  --name opsrabbit-spot --connection-arn "$CONNECTION_ARN" \
  --invocation-endpoint "$WEBHOOK_URL" --http-method POST \
  --invocation-rate-limit-per-second 10 --query ApiDestinationArn --output text)

cat > "$WORK_DIR/pattern.json" <<'JSON'
{"source":["aws.ec2"],"detail-type":["EC2 Spot Instance Interruption Warning","EC2 Instance Rebalance Recommendation"]}
JSON
RULE_ARN=$(opsaws events put-rule --name opsrabbit-spot --event-bus-name default \
  --event-pattern "file://$WORK_DIR/pattern.json" --state ENABLED --query RuleArn --output text)

jq -n --arg account "$OPS_ACCOUNT" --arg rule "$RULE_ARN" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"events.amazonaws.com"},Action:"sts:AssumeRole",Condition:{StringEquals:{"aws:SourceAccount":$account},ArnEquals:{"aws:SourceArn":$rule}}}]}' > "$WORK_DIR/trust.json"
ROLE_ARN=$(opsaws iam create-role --role-name OpsRabbitSpotDelivery \
  --assume-role-policy-document "file://$WORK_DIR/trust.json" --query Role.Arn --output text)
jq -n --arg destination "$DEST_ARN" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"events:InvokeApiDestination",Resource:$destination}]}' > "$WORK_DIR/invoke.json"
opsaws iam put-role-policy --role-name OpsRabbitSpotDelivery --policy-name InvokeOpsRabbit \
  --policy-document "file://$WORK_DIR/invoke.json"

# Normalize AWS events into OpsRabbit's generic webhook fields.
jq -n --arg destination "$DEST_ARN" --arg role "$ROLE_ARN" '[{
  Id:"OpsRabbit",Arn:$destination,RoleArn:$role,
  RetryPolicy:{MaximumEventAgeInSeconds:300,MaximumRetryAttempts:10},
  InputTransformer:{
    InputPathsMap:{id:"$.id",kind:"$.detail-type",instance:"$.detail.instance-id",time:"$.time",account:"$.account",region:"$.region"},
    InputTemplate:"{\"id\":<id>,\"title\":<kind>,\"event_type\":<kind>,\"resource\":<instance>,\"timestamp\":<time>,\"severity\":\"warning\",\"tags\":{\"provider\":\"aws\",\"account\":<account>,\"region\":<region>}}"
  }
}]' > "$WORK_DIR/targets.json"
opsaws events put-targets --rule opsrabbit-spot --event-bus-name default \
  --targets "file://$WORK_DIR/targets.json"
```

`put-targets` must report `FailedEntryCount: 0`; an exit code alone does not prove success. If IAM permissions have not propagated, inspect the failure and repeat the last command after propagation. Save the generated target file for troubleshooting; it contains no webhook token.

**Same account:** setup is complete for Spot instances in this account and Region. Follow the validation section below.

## 3 Add a different AWS account

Suppose OpsRabbit is in account **111111111111** and Spot instances are in account **222222222222**. The source account forwards the original event to OpsRabbit's default bus; it does not need access to the webhook token, private DNS, or VPC Lattice resource. No VPC peering or RAM resource share is needed for this bus-to-bus design.

First, in the same OpsRabbit-admin terminal, allow the specific sender account to publish to the receiving bus:

```bash
SOURCE_ACCOUNT=222222222222
opsaws events put-permission --event-bus-name default \
  --statement-id "AllowSpotFrom${SOURCE_ACCOUNT}" \
  --action events:PutEvents --principal "$SOURCE_ACCOUNT"
```

Then, in a **separate Bash terminal**, run as the source-account administrator. Edit the profile, Region and receiving account ID. This sample also assumes unused role/rule names.

```bash
set -euo pipefail
export AWS_PAGER=''
SOURCE_PROFILE=spot-account-admin
REGION=us-east-1
OPS_ACCOUNT=111111111111
srcaws() { aws --profile "$SOURCE_PROFILE" --region "$REGION" "$@"; }
SOURCE_ACCOUNT=$(srcaws sts get-caller-identity --query Account --output text)
BUS_ARN="arn:aws:events:${REGION}:${OPS_ACCOUNT}:event-bus/default"
umask 077
SOURCE_WORK_DIR=$(mktemp -d)

cat > "$SOURCE_WORK_DIR/pattern.json" <<'JSON'
{"source":["aws.ec2"],"detail-type":["EC2 Spot Instance Interruption Warning","EC2 Instance Rebalance Recommendation"]}
JSON
SOURCE_RULE_ARN=$(srcaws events put-rule --name forward-spot-to-opsrabbit \
  --event-bus-name default --event-pattern "file://$SOURCE_WORK_DIR/pattern.json" \
  --state ENABLED --query RuleArn --output text)
jq -n --arg account "$SOURCE_ACCOUNT" --arg rule "$SOURCE_RULE_ARN" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"events.amazonaws.com"},Action:"sts:AssumeRole",Condition:{StringEquals:{"aws:SourceAccount":$account},ArnEquals:{"aws:SourceArn":$rule}}}]}' > "$SOURCE_WORK_DIR/trust.json"
SOURCE_ROLE_ARN=$(srcaws iam create-role --role-name ForwardSpotToOpsRabbit \
  --assume-role-policy-document "file://$SOURCE_WORK_DIR/trust.json" --query Role.Arn --output text)
jq -n --arg bus "$BUS_ARN" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"events:PutEvents",Resource:$bus}]}' > "$SOURCE_WORK_DIR/forward.json"
srcaws iam put-role-policy --role-name ForwardSpotToOpsRabbit --policy-name PublishSpotEvents \
  --policy-document "file://$SOURCE_WORK_DIR/forward.json"
jq -n --arg bus "$BUS_ARN" --arg role "$SOURCE_ROLE_ARN" \
  '[{Id:"OpsRabbitAccount",Arn:$bus,RoleArn:$role,RetryPolicy:{MaximumEventAgeInSeconds:300,MaximumRetryAttempts:10}}]' > "$SOURCE_WORK_DIR/targets.json"
srcaws events put-targets --rule forward-spot-to-opsrabbit --event-bus-name default \
  --targets "file://$SOURCE_WORK_DIR/targets.json"
```

Again, require `FailedEntryCount: 0`. Forward the original event unchanged; normalization happens only in the receiving account's API Destination target. Add one permission statement per approved source account, and restrict the receiving rule's `account` field to the approved source/hosting accounts if the bus has other publishers. [AWS cross-account setup](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cross-account.html).

## 4 Validate and operate

- From a machine with private access, open the HTTPS hostname and verify the certificate without bypassing TLS verification. Confirm the configured inbound is enabled, its token matches, and its assigned agent has the required access.
- In EventBridge, confirm the Connection is `AUTHORIZED`, both rules have the correct targets, and `FailedInvocations` remains zero. Check OpsRabbit inbound history for the source account, Region and instance ID after a controlled interruption of a disposable Spot instance. An EC2 manual stop is not proof of a genuine Spot interruption notice; use a supported AWS Fault Injection Service Spot interruption experiment when validating the full path.
- Monitor failures and configure dead-letter queues for both target hops before relying on delivery in production. These minimal examples include bounded retries but do not create queues. A dead-letter queue recovers event history, not the lost warning window. Late events must not trigger time-sensitive remediation blindly.
- AWS normally provides about two minutes before Spot stop/termination, on a best-effort basis; hibernation starts immediately. Rebalance recommendations mean elevated risk and may arrive alongside the interruption warning. The AWS event `time` is notice time, not an explicit shutdown deadline. [AWS interruption notices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html).
- EventBridge requires the webhook response within five seconds. OpsRabbit schedules agent processing asynchronously, but configuration/database work precedes its HTTP response. Measure deployed acceptance latency separately from investigation duration. Preserve event IDs across retries and do not assume exactly-once delivery.
- Cleanup requires removing rule targets/rules, API Destination, Connection, IAM roles/policies and source-account bus permissions you created. Removing the Connection also removes its EventBridge-managed private association; remove dedicated gateway/resource/DNS configuration only after confirming it has no other consumers.

These commands provision AWS resources when you run them. The installer itself does not provision EventBridge, VPC Lattice, DNS or certificates.
