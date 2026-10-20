# Send AWS Spot notifications to private OpsRabbit

This walkthrough connects AWS Spot notifications to the existing OpsRabbit webhook. OpsRabbit stays on private EC2. No Lambda, public EC2 IP or VM watcher is required; EventBridge reaches the HTTPS endpoint through VPC Lattice.

| Your setup | Follow these steps |
| --- | --- |
| Spot and OpsRabbit in the same account | [Steps 1–5](#1-enable-https-and-create-the-inbound), then [safe testing](#7-test-without-interrupting-an-instance) |
| Spot in another account | Steps 1–7; the source-account admin performs [step 6](#6-add-a-source-aws-account) |

```text
Same account:  Spot → default EventBridge bus → private API Destination → OpsRabbit
Cross account: Spot → source default bus → OpsRabbit default bus → same destination
```

Both accounts must use the **same Region** for this walkthrough. Other Regions need a separate regional setup or a deliberately configured cross-Region route. Examples use the standard AWS partition. EventBridge, VPC Lattice and Connection secrets can incur AWS charges.

For later reference: [resume a partial setup](#resume-after-a-partial-failure), [troubleshoot delivery](#troubleshooting), or review the [production checklist](#before-production-use).

## Before you start

Use an installer/helper version that includes `opsrabbitctl https configure`; follow the linked HTTPS guide to upgrade the helper and its libraries if needed. Use Bash, a current AWS CLI v2 and `jq`. Sign in to the intended AWS profiles first, for example using your organization's AWS IAM Identity Center process. Run the AWS commands on an admin workstation or CloudShell. DNS/HTTPS tests need a machine with private network access, such as the OpsRabbit host or a VPN-connected workstation.

The setup administrator needs permissions to manage the relevant EC2 network/security-group settings, VPC Lattice resources, EventBridge rules/Connections/API Destinations, and IAM roles including `iam:PassRole`. Connection creation also needs its Secrets Manager/service-linked-role permissions and the VPC Lattice association permissions described in [AWS private connections](https://docs.aws.amazon.com/eventbridge/latest/userguide/connection-private.html). Runtime roles below are limited to their specific destination or event bus.

### Collect these inputs

All IDs below are examples. Replace them with your own values; do not copy the example account IDs unchanged.

| Input | Example | Where to find it |
| --- | --- | --- |
| `OPS_PROFILE` | `opsrabbit-admin` | Your local AWS CLI profile for the account hosting OpsRabbit |
| `OPS_ACCOUNT` | `111111111111` | Account ID shown after signing in to that account |
| `REGION` | `us-east-1` | Region containing OpsRabbit and the Spot instances covered by this setup |
| `NAME` | `opsrabbit-spot` | A short, unused name for this notification setup |
| `HOST_NAME` | `opsrabbit.example.com` | A hostname under a domain your organization controls |
| `WEBHOOK_URL` | `https://opsrabbit.example.com/webhooks/inbound/aws-spot` | Exact instance URL copied from the OpsRabbit Webhook Inbound |
| Webhook Token | Entered privately when prompted | Token configured on that inbound; never put it in a URL |
| `VPC_ID` | `vpc-0123456789abcdef0` | EC2 instance → Networking → VPC ID |
| `SUBNET_IDS` | Two subnet IDs in different Availability Zones | VPC → Subnets; both must belong to that VPC and reach OpsRabbit |
| EC2 private IP | `10.0.10.25` | EC2 instance → Networking; used for the private DNS record |
| EC2 security group ID | `sg-0123456789abcdef0` | EC2 instance → Security; used in step 3 |
| `GATEWAY_SG_ID` | `sg-0fedcba9876543210` | Dedicated gateway security group created in step 3 |
| `SOURCE_PROFILE` and `SOURCE_ACCOUNT` | `spot-account-admin`, `222222222222` | Only for cross-account setup; supplied by that account's admin |

For the first test, assign the inbound an agent **without cloud mutation tools or automatic remediation**. A synthetic event can still start agent processing. Keep this restriction until the test is complete and any production actions are explicitly authorized.

## 1 Enable HTTPS and create the inbound

On the OpsRabbit host, use the deployment user and your certificate files:

```bash
opsrabbitctl https configure \
  --hostname opsrabbit.example.com \
  --cert /secure/path/fullchain.pem \
  --key /secure/path/privkey.pem \
  --http-mode keep
```

**Expected:** `HTTPS configured at https://opsrabbit.example.com; HTTP mode: keep.` HTTP remains available, but use HTTPS for webhook credentials. See [HTTPS configuration](../README.md#post-install-https-with-the-existing-nginx) for renewal, certificate permissions and other HTTP modes.

Use a publicly trusted certificate matching `HOST_NAME`. Obtain it from your chosen issuer using public DNS validation if the instance cannot receive internet traffic. The public validation record proves domain ownership; it does not expose the instance.

In OpsRabbit, create a **Webhook Inbound**, set a strong Webhook Token, select the restricted test agent described above, enable the inbound and copy its exact HTTPS URL.

## 2 Set up private DNS and confirm HTTPS

In Route 53:

1. Use an existing private hosted zone that covers the hostname, or create a private zone for `opsrabbit.example.com`.
2. Associate it with OpsRabbit's VPC in the selected Region.
3. Create an **A record** for `opsrabbit.example.com` pointing to the EC2 private IP. In a zone named exactly `opsrabbit.example.com`, leave the record-name field blank. If a record already exists, confirm it points to the intended instance before changing anything.
4. Confirm the VPC has DNS resolution enabled. Keep the certificate issuer's validation records in **public DNS**, separate from this private A record.

From a machine with private access, replace the hostname and run:

```bash
curl --noproxy '*' --connect-timeout 5 --max-time 15 \
  --fail --silent --show-error --output /dev/null \
  --write-out 'HTTP %{http_code}\n' https://opsrabbit.example.com/
```

**Expected:** `HTTP 200`, with no certificate error. Do not use `-k` or `--insecure`. Stop here if DNS, routing or TLS fails; see troubleshooting below. This check proves private client access, not yet EventBridge access.

## 3 Allow EventBridge private access

### Create the gateway security group

In the EC2/VPC security-group console, create a dedicated security group in OpsRabbit's VPC, for example `opsrabbit-spot-gateway`.

| Security group | Direction | Rule |
| --- | --- | --- |
| Gateway group | Outbound | TCP 443, destination = OpsRabbit EC2 security group |
| OpsRabbit EC2 group | Inbound | TCP 443, source = gateway group |

Replace the new gateway group's default allow-all outbound rule with the narrow rule above. No inbound rule is required on the gateway group for this resource traffic. Preserve unrelated rules on the EC2 group. Confirm subnet routes/network ACLs permit the connection and return traffic. [AWS resource gateway networking](https://docs.aws.amazon.com/vpc/latest/privatelink/resource-gateway.html).

### Initialize the OpsRabbit admin terminal

Edit the values and run this **once for a new setup**. For cross-account delivery, include both account IDs in `ALLOWED_ACCOUNTS`. For same-account delivery, include only `OPS_ACCOUNT`.

```bash
set -euo pipefail
set +x
export AWS_PAGER=''
umask 077
OPS_PROFILE=opsrabbit-admin
OPS_ACCOUNT=111111111111
REGION=us-east-1
NAME=opsrabbit-spot
HOST_NAME=opsrabbit.example.com
WEBHOOK_URL=https://opsrabbit.example.com/webhooks/inbound/aws-spot
VPC_ID=vpc-0123456789abcdef0
SUBNET_IDS=(subnet-0123456789abcdef0 subnet-0fedcba9876543210)
GATEWAY_SG_ID=sg-0fedcba9876543210
ALLOWED_ACCOUNTS=(111111111111) # Cross-account: (111111111111 222222222222)
ROLE_NAME="${NAME}-delivery-${REGION}"
opsaws() { aws --profile "$OPS_PROFILE" --region "$REGION" "$@"; }
[[ "$(opsaws sts get-caller-identity --query Account --output text)" == "$OPS_ACCOUNT" ]] || { echo 'Wrong AWS account; stop and correct the profile.' >&2; exit 1; }
WORK_DIR="$PWD/${NAME}-setup"
mkdir -m 700 "$WORK_DIR"
GATEWAY_ID='' RESOURCE_ARN='' CONNECTION_ARN='' DEST_ARN='' RULE_ARN='' ROLE_ARN=''
TEST_RULE_NAME='' TEST_ROLE_NAME='' TEST_RULE_ARN='' TEST_ROLE_ARN=''
save_ops_state() {
  {
    declare -p OPS_PROFILE OPS_ACCOUNT REGION NAME HOST_NAME WEBHOOK_URL VPC_ID SUBNET_IDS GATEWAY_SG_ID ALLOWED_ACCOUNTS ROLE_NAME WORK_DIR GATEWAY_ID RESOURCE_ARN CONNECTION_ARN DEST_ARN RULE_ARN ROLE_ARN TEST_RULE_NAME TEST_ROLE_NAME TEST_RULE_ARN TEST_ROLE_ARN
    declare -f opsaws save_ops_state
  } > "$WORK_DIR/state.sh.new"
  mv "$WORK_DIR/state.sh.new" "$WORK_DIR/state.sh"
}
save_ops_state
printf 'Setup directory: %s\n' "$WORK_DIR"
```

**Expected:** your setup-directory path. An existing directory causes this block to stop rather than overwrite saved work. It contains identifiers and policies, not the webhook token. Keep this terminal open; subsequent blocks use these variables. To resume in a new Bash terminal, run `source /absolute/path/to/opsrabbit-spot-setup/state.sh` and verify the profile's account again before writes.

### Create the resource gateway

```bash
GATEWAY_ID=$(opsaws vpc-lattice create-resource-gateway \
  --name "$NAME" --vpc-identifier "$VPC_ID" \
  --subnet-ids "${SUBNET_IDS[@]}" --security-group-ids "$GATEWAY_SG_ID" \
  --ip-address-type IPV4 --resource-config-dns-resolution IN_VPC \
  --query id --output text)
save_ops_state
opsaws vpc-lattice get-resource-gateway --resource-gateway-identifier "$GATEWAY_ID" \
  --query '{Status:status,DNS:resourceConfigDnsResolution}'
```

**Expected:** `Status` becomes `ACTIVE`, and `DNS` is `IN_VPC`. Re-run the status command while creation is in progress. If creation fails, inspect the gateway in the console before continuing. `IN_VPC` lets it resolve your private DNS record and cannot be changed on that gateway later. [AWS gateway options](https://docs.aws.amazon.com/cli/latest/reference/vpc-lattice/create-resource-gateway.html).

### Register the HTTPS endpoint

```bash
jq -n --arg host "$HOST_NAME" '{dnsResource:{domainName:$host,ipAddressType:"IPV4"}}' > "$WORK_DIR/resource.json"
RESOURCE_ARN=$(opsaws vpc-lattice create-resource-configuration \
  --name "$NAME" --type SINGLE --resource-gateway-identifier "$GATEWAY_ID" \
  --protocol TCP --port-ranges 443 \
  --resource-configuration-definition "file://$WORK_DIR/resource.json" \
  --query arn --output text)
save_ops_state
opsaws vpc-lattice get-resource-configuration --resource-configuration-identifier "$RESOURCE_ARN" \
  --query '{Status:status,Arn:arn}'
```

**Expected:** `Status: ACTIVE` and an ARN ending in `resourceconfiguration/rcfg-…`. Wait for `ACTIVE` before continuing. You do not need to create a separate service-network association: EventBridge manages its association in the next step. [AWS private connections](https://docs.aws.amazon.com/eventbridge/latest/userguide/connection-private.html).

## 4 Connect EventBridge to the webhook

### Store the inbound authentication

Run in the OpsRabbit admin terminal. The token is entered privately and sent through a protected file, not a command-line argument.

```bash
trap 'rm -f "$WORK_DIR/auth.json"; unset OPSRABBIT_WEBHOOK_TOKEN' EXIT
read -r -s -p 'OpsRabbit Webhook Token: ' OPSRABBIT_WEBHOOK_TOKEN
printf '\n'
[[ -n "$OPSRABBIT_WEBHOOK_TOKEN" ]] || { echo 'Webhook token cannot be empty.' >&2; exit 1; }
export OPSRABBIT_WEBHOOK_TOKEN
jq -n '{ApiKeyAuthParameters:{ApiKeyName:"x-opsrabbit-webhook-token",ApiKeyValue:env.OPSRABBIT_WEBHOOK_TOKEN}}' > "$WORK_DIR/auth.json"
unset OPSRABBIT_WEBHOOK_TOKEN
CONNECTION_ARN=$(opsaws events create-connection \
  --name "$NAME" --authorization-type API_KEY \
  --auth-parameters "file://$WORK_DIR/auth.json" \
  --invocation-connectivity-parameters "ResourceParameters={ResourceConfigurationArn=$RESOURCE_ARN}" \
  --query ConnectionArn --output text)
rm "$WORK_DIR/auth.json"
save_ops_state
opsaws events describe-connection --name "$NAME" \
  --query '{State:ConnectionState,Reason:StateReason}'
```

**Expected:** `State: AUTHORIZED`. Re-run `describe-connection` while authorization is in progress. If it fails, check its reason and the VPC Lattice association permissions. Authorization alone does **not** prove that the webhook can be reached or that its token is accepted; test delivery in step 7.

### Create the API Destination

```bash
DEST_ARN=$(opsaws events create-api-destination \
  --name "$NAME" --connection-arn "$CONNECTION_ARN" \
  --invocation-endpoint "$WEBHOOK_URL" --http-method POST \
  --invocation-rate-limit-per-second 10 --query ApiDestinationArn --output text)
save_ops_state
opsaws events describe-api-destination --name "$NAME" \
  --query '{State:ApiDestinationState,URL:InvocationEndpoint}'
```

**Expected:** `State: ACTIVE`, with the exact inbound HTTPS URL. API Destinations require an HTTPS hostname with a publicly trusted certificate even for private access; a private IP or self-signed certificate is insufficient. [AWS endpoint requirements](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-api-destinations.html).

## 5 Route Spot events to OpsRabbit

### Create the receiving rule

```bash
jq -n --args '{source:["aws.ec2"],"detail-type":["EC2 Spot Instance Interruption Warning","EC2 Instance Rebalance Recommendation"],account:$ARGS.positional}' \
  "${ALLOWED_ACCOUNTS[@]}" > "$WORK_DIR/pattern.json"
RULE_ARN=$(opsaws events put-rule --name "$NAME" --event-bus-name default \
  --event-pattern "file://$WORK_DIR/pattern.json" --state ENABLED --query RuleArn --output text)
save_ops_state
printf '%s\n' "$RULE_ARN"
```

**Expected:** `arn:aws:events:REGION:OPS_ACCOUNT:rule/NAME`. This accepts genuine Spot warnings and rebalance recommendations only from the accounts you listed. Rebalance indicates elevated risk, not certain imminent interruption.

### Grant permission to invoke this destination

```bash
jq -n --arg account "$OPS_ACCOUNT" --arg rule "$RULE_ARN" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"events.amazonaws.com"},Action:"sts:AssumeRole",Condition:{StringEquals:{"aws:SourceAccount":$account},ArnEquals:{"aws:SourceArn":$rule}}}]}' > "$WORK_DIR/trust.json"
ROLE_ARN=$(opsaws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document "file://$WORK_DIR/trust.json" --query Role.Arn --output text)
save_ops_state
jq -n --arg destination "$DEST_ARN" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"events:InvokeApiDestination",Resource:$destination}]}' > "$WORK_DIR/invoke.json"
opsaws iam put-role-policy --role-name "$ROLE_NAME" --policy-name InvokeOpsRabbit \
  --policy-document "file://$WORK_DIR/invoke.json"
```

**Expected:** role creation succeeds and `put-role-policy` returns without an error. This role can invoke only this destination and can be assumed only for the receiving rule.

### Attach the target and normalize the payload

```bash
jq -n --arg destination "$DEST_ARN" --arg role "$ROLE_ARN" '[{
  Id:"OpsRabbit",Arn:$destination,RoleArn:$role,
  RetryPolicy:{MaximumEventAgeInSeconds:300,MaximumRetryAttempts:10},
  InputTransformer:{
    InputPathsMap:{id:"$.id",kind:"$.detail-type",instance:"$.detail.instance-id",time:"$.time",account:"$.account",region:"$.region"},
    InputTemplate:"{\"id\":<id>,\"title\":<kind>,\"event_type\":<kind>,\"resource\":<instance>,\"timestamp\":<time>,\"severity\":\"warning\",\"tags\":{\"provider\":\"aws\",\"account\":<account>,\"region\":<region>}}"
  }
}]' > "$WORK_DIR/targets.json"
opsaws events put-targets --rule "$NAME" --event-bus-name default \
  --targets "file://$WORK_DIR/targets.json"
```

**Expected:** `{"FailedEntryCount":0,"FailedEntries":[]}`. Inspect this result even when the CLI exits successfully. If an entry fails, correct its error and repeat **only this last command**. IAM changes can take time to propagate.

Same-account routing is configured. For cross-account delivery, continue below; otherwise go to step 7.

## 6 Add a source AWS account

### Allow the source account on the receiving bus

In the **OpsRabbit admin terminal**, set the source account ID:

```bash
SOURCE_ACCOUNT=222222222222
opsaws events put-permission --event-bus-name default \
  --statement-id "${NAME}-${SOURCE_ACCOUNT}" \
  --action events:PutEvents --principal "$SOURCE_ACCOUNT"
```

**Expected:** no error. Confirm this account is also in `ALLOWED_ACCOUNTS` for the receiving rule. If you add it later, regenerate `pattern.json` and repeat `put-rule` from step 5 without recreating its role or target.

### Initialize the source admin terminal

Open a **separate Bash terminal** with the source account's profile. Use the same `REGION`, receiving `OPS_ACCOUNT`, and `NAME` as above.

```bash
set -euo pipefail
set +x
export AWS_PAGER=''
umask 077
SOURCE_PROFILE=spot-account-admin
SOURCE_ACCOUNT=222222222222
OPS_ACCOUNT=111111111111
REGION=us-east-1
NAME=opsrabbit-spot
SOURCE_ROLE_NAME="${NAME}-forward-${REGION}"
BUS_ARN="arn:aws:events:${REGION}:${OPS_ACCOUNT}:event-bus/default"
srcaws() { aws --profile "$SOURCE_PROFILE" --region "$REGION" "$@"; }
[[ "$(srcaws sts get-caller-identity --query Account --output text)" == "$SOURCE_ACCOUNT" ]] || { echo 'Wrong source account; stop and correct the profile.' >&2; exit 1; }
SOURCE_WORK_DIR="$PWD/${NAME}-source-setup"
mkdir -m 700 "$SOURCE_WORK_DIR"
SOURCE_RULE_ARN='' SOURCE_ROLE_ARN=''
SOURCE_TEST_RULE_NAME='' SOURCE_TEST_ROLE_NAME='' SOURCE_TEST_RULE_ARN='' SOURCE_TEST_ROLE_ARN=''
save_source_state() {
  {
    declare -p SOURCE_PROFILE SOURCE_ACCOUNT OPS_ACCOUNT REGION NAME SOURCE_ROLE_NAME BUS_ARN SOURCE_WORK_DIR SOURCE_RULE_ARN SOURCE_ROLE_ARN SOURCE_TEST_RULE_NAME SOURCE_TEST_ROLE_NAME SOURCE_TEST_RULE_ARN SOURCE_TEST_ROLE_ARN
    declare -f srcaws save_source_state
  } > "$SOURCE_WORK_DIR/state.sh.new"
  mv "$SOURCE_WORK_DIR/state.sh.new" "$SOURCE_WORK_DIR/state.sh"
}
save_source_state
```

**Expected:** no error. Resume this terminal later with `source /absolute/path/to/opsrabbit-spot-source-setup/state.sh`. The source account needs neither the webhook token nor access to OpsRabbit's VPC. Bus forwarding does not require VPC peering or a RAM share.

### Create the forwarding rule and role

```bash
jq -n --arg account "$SOURCE_ACCOUNT" '{source:["aws.ec2"],"detail-type":["EC2 Spot Instance Interruption Warning","EC2 Instance Rebalance Recommendation"],account:[$account]}' > "$SOURCE_WORK_DIR/pattern.json"
SOURCE_RULE_ARN=$(srcaws events put-rule --name "$NAME-forward" \
  --event-bus-name default --event-pattern "file://$SOURCE_WORK_DIR/pattern.json" \
  --state ENABLED --query RuleArn --output text)
save_source_state
jq -n --arg account "$SOURCE_ACCOUNT" --arg rule "$SOURCE_RULE_ARN" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"events.amazonaws.com"},Action:"sts:AssumeRole",Condition:{StringEquals:{"aws:SourceAccount":$account},ArnEquals:{"aws:SourceArn":$rule}}}]}' > "$SOURCE_WORK_DIR/trust.json"
SOURCE_ROLE_ARN=$(srcaws iam create-role --role-name "$SOURCE_ROLE_NAME" \
  --assume-role-policy-document "file://$SOURCE_WORK_DIR/trust.json" --query Role.Arn --output text)
save_source_state
jq -n --arg bus "$BUS_ARN" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"events:PutEvents",Resource:$bus}]}' > "$SOURCE_WORK_DIR/forward.json"
srcaws iam put-role-policy --role-name "$SOURCE_ROLE_NAME" --policy-name PublishSpotEvents \
  --policy-document "file://$SOURCE_WORK_DIR/forward.json"
```

**Expected:** a source rule ARN and role ARN are saved. The role is limited to forwarding from this rule to the receiving bus.

### Attach the receiving bus

```bash
jq -n --arg bus "$BUS_ARN" --arg role "$SOURCE_ROLE_ARN" \
  '[{Id:"OpsRabbitAccount",Arn:$bus,RoleArn:$role,RetryPolicy:{MaximumEventAgeInSeconds:300,MaximumRetryAttempts:10}}]' > "$SOURCE_WORK_DIR/targets.json"
srcaws events put-targets --rule "$NAME-forward" --event-bus-name default \
  --targets "file://$SOURCE_WORK_DIR/targets.json"
```

**Expected:** `FailedEntryCount: 0`. The original event remains unchanged; payload normalization happens only in the OpsRabbit account. [AWS cross-account delivery](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cross-account.html).

## 7 Test without interrupting an instance

Keep the inbound's agent restricted from mutation/remediation while testing. These tests create a harmless custom event with resource `TEST-NOT-A-REAL-INSTANCE`; they do not stop, terminate or preempt any EC2 instance. They can still produce an OpsRabbit investigation and model usage.

### Check the production event pattern without delivering an alert

In the OpsRabbit admin terminal:

```bash
jq -n --arg account "$OPS_ACCOUNT" --arg region "$REGION" \
  '{version:"0",id:"00000000-0000-4000-8000-000000000001",account:$account,region:$region,time:"2026-10-20T00:00:00Z",source:"aws.ec2","detail-type":"EC2 Spot Instance Interruption Warning",resources:[],detail:{"instance-id":"TEST-NOT-A-REAL-INSTANCE","instance-action":"terminate"}}' > "$WORK_DIR/sample-event.json"
opsaws events test-event-pattern --event-pattern "file://$WORK_DIR/pattern.json" \
  --event "file://$WORK_DIR/sample-event.json"
```

**Expected:** `{"Result":true}`. For a source-account check, use its account ID in the sample and its forwarding pattern. This API only checks matching; it does not publish an event or validate networking.

### Create a temporary test receiver

In the **OpsRabbit admin terminal**, create a separate rule and role. The production rule and its IAM trust policy stay unchanged.

```bash
TEST_RULE_NAME="$NAME-test"
TEST_ROLE_NAME="${NAME}-test-${REGION}"
TEST_RULE_ARN=$(opsaws events put-rule --name "$TEST_RULE_NAME" --event-bus-name default \
  --event-pattern "$(jq -cn --args '{source:["opsrabbit.spot-test"],"detail-type":["[TEST] OpsRabbit delivery test"],account:$ARGS.positional}' "${ALLOWED_ACCOUNTS[@]}")" \
  --state ENABLED --query RuleArn --output text)
save_ops_state
jq --arg rule "$TEST_RULE_ARN" '.Statement[0].Condition.ArnEquals["aws:SourceArn"]=$rule' "$WORK_DIR/trust.json" > "$WORK_DIR/test-trust.json"
TEST_ROLE_ARN=$(opsaws iam create-role --role-name "$TEST_ROLE_NAME" \
  --assume-role-policy-document "file://$WORK_DIR/test-trust.json" --query Role.Arn --output text)
save_ops_state
opsaws iam put-role-policy --role-name "$TEST_ROLE_NAME" --policy-name InvokeOpsRabbit \
  --policy-document "file://$WORK_DIR/invoke.json"
jq --arg role "$TEST_ROLE_ARN" 'map(.RoleArn=$role)' "$WORK_DIR/targets.json" > "$WORK_DIR/test-targets.json"
opsaws events put-targets --rule "$TEST_RULE_NAME" --event-bus-name default \
  --targets "file://$WORK_DIR/test-targets.json"
```

**Expected:** `FailedEntryCount: 0`. If the temporary role has not propagated, repeat the final `put-targets` after checking the error. To recover this test setup after closing the terminal, load the saved setup context and use the same test rule/role names; use the lookup guidance below instead of creating duplicate roles.

For **same-account testing**, publish this custom event from the OpsRabbit terminal:

```bash
opsaws events put-events --entries '[{"Source":"opsrabbit.spot-test","DetailType":"[TEST] OpsRabbit delivery test","Detail":"{\"instance-id\":\"TEST-NOT-A-REAL-INSTANCE\"}","EventBusName":"default"}]'
```

**Expected:** `FailedEntryCount: 0` and an `EventId`. In OpsRabbit inbound history, find `[TEST] OpsRabbit delivery test`, resource `TEST-NOT-A-REAL-INSTANCE`, and the correct account/Region tags. Event acceptance alone does not prove webhook delivery; inspect the inbound receipt as well.

### Test the cross-account hop

Skip this subsection for same-account setup. Leave the temporary receiver above in place. In the **source admin terminal**, add a temporary forwarding rule and role:

```bash
SOURCE_TEST_RULE_NAME="$NAME-forward-test"
SOURCE_TEST_ROLE_NAME="${NAME}-forward-test-${REGION}"
SOURCE_TEST_RULE_ARN=$(srcaws events put-rule --name "$SOURCE_TEST_RULE_NAME" --event-bus-name default \
  --event-pattern '{"source":["opsrabbit.spot-test"],"detail-type":["[TEST] OpsRabbit delivery test"]}' \
  --state ENABLED --query RuleArn --output text)
save_source_state
jq --arg rule "$SOURCE_TEST_RULE_ARN" '.Statement[0].Condition.ArnEquals["aws:SourceArn"]=$rule' "$SOURCE_WORK_DIR/trust.json" > "$SOURCE_WORK_DIR/test-trust.json"
SOURCE_TEST_ROLE_ARN=$(srcaws iam create-role --role-name "$SOURCE_TEST_ROLE_NAME" \
  --assume-role-policy-document "file://$SOURCE_WORK_DIR/test-trust.json" --query Role.Arn --output text)
save_source_state
srcaws iam put-role-policy --role-name "$SOURCE_TEST_ROLE_NAME" --policy-name PublishSpotEvents \
  --policy-document "file://$SOURCE_WORK_DIR/forward.json"
jq --arg role "$SOURCE_TEST_ROLE_ARN" 'map(.RoleArn=$role)' "$SOURCE_WORK_DIR/targets.json" > "$SOURCE_WORK_DIR/test-targets.json"
srcaws events put-targets --rule "$SOURCE_TEST_RULE_NAME" --event-bus-name default \
  --targets "file://$SOURCE_WORK_DIR/test-targets.json"
```

Require `FailedEntryCount: 0` before publishing:

```bash
srcaws events put-events --entries '[{"Source":"opsrabbit.spot-test","DetailType":"[TEST] OpsRabbit delivery test","Detail":"{\"instance-id\":\"TEST-NOT-A-REAL-INSTANCE\"}","EventBusName":"default"}]'
```

**Expected:** acceptance with zero failed entries, followed by the same test receipt in OpsRabbit, tagged with the **source account**. This checks both bus forwarding and private webhook delivery. The custom source is intentional; do not try to publish synthetic events under the reserved `aws.ec2` source.

### Remove only the temporary test resources

First remove the temporary source resources, if created, using the **source terminal**:

```bash
srcaws events remove-targets --rule "$SOURCE_TEST_RULE_NAME" --event-bus-name default --ids OpsRabbitAccount
srcaws events delete-rule --name "$SOURCE_TEST_RULE_NAME" --event-bus-name default
srcaws iam delete-role-policy --role-name "$SOURCE_TEST_ROLE_NAME" --policy-name PublishSpotEvents
srcaws iam delete-role --role-name "$SOURCE_TEST_ROLE_NAME"
SOURCE_TEST_RULE_ARN='' SOURCE_TEST_ROLE_ARN=''
save_source_state
```

Then remove the temporary receiver using the **OpsRabbit terminal**:

```bash
opsaws events remove-targets --rule "$TEST_RULE_NAME" --event-bus-name default --ids OpsRabbit
opsaws events delete-rule --name "$TEST_RULE_NAME" --event-bus-name default
opsaws iam delete-role-policy --role-name "$TEST_ROLE_NAME" --policy-name InvokeOpsRabbit
opsaws iam delete-role --role-name "$TEST_ROLE_NAME"
TEST_RULE_ARN='' TEST_ROLE_ARN=''
save_ops_state
```

**Expected:** zero failed target removals, then successful deletion. Do not substitute the production role/rule names here. Production routing remains enabled.

The synthetic test proves configured delivery, not AWS's real interruption timing. A full native interruption test is optional and disruptive: use an authorized AWS Fault Injection Service experiment against a **disposable Spot instance only**. A manual EC2 stop does not establish that a genuine Spot warning was delivered.

## Resume after a partial failure

Do not restart every `create-*` command. Load the appropriate saved `state.sh`, confirm the AWS account, and continue from the failed stage. If AWS created a resource before the terminal lost its response, recover its ARN/ID first:

| Resource | Read-only lookup in the correct account |
| --- | --- |
| Gateway | VPC Lattice console → Resource gateways → your `NAME`; copy its ID into `GATEWAY_ID` |
| Resource configuration | VPC Lattice console → Resource configurations → your `NAME`; copy its ARN into `RESOURCE_ARN` |
| Connection | `opsaws events describe-connection --name "$NAME" --query ConnectionArn --output text` |
| API Destination | `opsaws events describe-api-destination --name "$NAME" --query ApiDestinationArn --output text` |
| Receiving rule | `opsaws events describe-rule --name "$NAME" --event-bus-name default --query Arn --output text` |
| Delivery role | `opsaws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text` |
| Source rule | `srcaws events describe-rule --name "$NAME-forward" --event-bus-name default --query Arn --output text` |
| Source role | `srcaws iam get-role --role-name "$SOURCE_ROLE_NAME" --query Role.Arn --output text` |

Assign the result to its matching variable and run `save_ops_state` or `save_source_state`. Test names/ARNs are saved too; for a response lost before saving, use those test names in the equivalent lookup. `put-rule`, `put-role-policy` and `put-targets` update existing configuration; repeat them only for resources belonging to this setup, using the intended policy/target file. If you added a DLQ or other target settings in the console, preserve them in the target file before reapplying it. Do not overwrite unrelated existing resources to clear an `AlreadyExists` error. If `auth.json` remains after a failed Connection creation, remove it before leaving the terminal and re-enter the token only when needed.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `Wrong AWS account` | Correct the profile; do not continue with a different account ID merely to bypass the check |
| Unknown CLI option `resource-config-dns-resolution` | Update AWS CLI v2; confirm private DNS gateway support in your Region |
| DNS cannot resolve the hostname | Private A record, hosted-zone/VPC association, VPC DNS settings and the testing machine's private DNS access |
| TLS hostname, chain or expiry error | Matching hostname, valid leaf certificate plus intermediates, and Nginx certificate rotation; do not bypass verification |
| Gateway/configuration not `ACTIVE` | Check console status/errors, subnet/VPC compatibility and available addresses |
| Connection not `AUTHORIZED` | Its state reason, resource ARN/Region and permissions for the EventBridge-managed association |
| HTTP `401` | Exact inbound URL and token; update the Connection credential if the inbound token changed |
| HTTP `404` | Copied instance URL, enabled inbound and Nginx `/webhooks/` routing |
| HTTP `503` or `5xx` | OpsRabbit inbound runtime/backend availability; inspect application logs |
| Target reports access denied | `iam:PassRole`, target role permission, rule-scoped trust, cross-account bus policy and IAM propagation |
| `put-events` succeeds but nothing arrives | Temporary test rules on both hops, approved account filter, `FailedInvocations`/delivery logs, gateway egress and EC2 ingress on 443 |
| Five-second delivery timeout | Private routing/TLS handshake, proxy behavior and OpsRabbit acceptance/database latency; agent completion should not be awaited |
| Duplicate or late alerts | Delivery retries and alert-routing policy; preserve event IDs and compare the event timestamp before remediation |

## Before production use

- Confirm the test receipt, source account, Region and resource fields in OpsRabbit. Remove temporary test rules/roles. Keep remediation disabled until its permissions and actions are intentionally configured.
- Configure a **standard SQS dead-letter queue in the target Region for each EventBridge target hop**, using the EventBridge target's retry/dead-letter settings. Verify its queue policy permits EventBridge to send messages from the intended rule, and monitor failed invocations and queue depth. The examples above set bounded retries but do not provision DLQs. [AWS dead-letter queues](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-rule-dlq.html).
- AWS normally gives roughly two minutes before Spot stop/termination, on a best-effort basis; hibernation starts immediately. Rebalance recommendations may arrive alongside the interruption warning. Event time is notice time, not a guaranteed shutdown deadline. Keep urgent draining/checkpointing in local or cloud-native handlers. [AWS interruption notices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html).
- The sample API Destination limit is 10 requests/second. Size it for your event volume; a low limit can queue warnings past their useful window.
- Measure deployed webhook acceptance against EventBridge's five-second limit. OpsRabbit schedules agent work asynchronously, but configuration/database work precedes the response. Do not assume exactly-once delivery or that a DLQ can recover a lost advance-warning window.
- Retain the protected setup directory as an administrator runbook, or remove it once identifiers/policies are recorded securely. Never retain webhook-token files there. To retire the integration, remove its targets/rules, roles/policies, destination, Connection and source-account bus permission; remove gateway, security-group and DNS resources only if dedicated and unused elsewhere.

The installer does not provision these AWS resources. The commands create them when the AWS administrator runs this walkthrough.
