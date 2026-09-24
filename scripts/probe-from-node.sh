#!/usr/bin/env bash
# Run mtr from the exit node to Singapore game-server networks (via SSM). Usage: scripts/probe-from-node.sh [stack] [region] [targets...]
set -euo pipefail
export MSYS_NO_PATHCONV=1
STACK=${1:-csvpn-sg}; REGION=${2:-ap-southeast-1}; shift 2 2>/dev/null || true
TARGETS=${*:-"139.99.112.177 103.14.247.211 23.106.253.161 35.240.144.156 103.10.124.116"}
IID=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
CMD=$(aws ssm send-command --region "$REGION" --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters "commands=[\"sudo wg show; for h in $TARGETS; do echo == \$h; sudo mtr -rwzc 5 -n \$h | tail -8; done\"]" \
  --query Command.CommandId --output text)
for _ in $(seq 1 40); do
  s=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD" --instance-id "$IID" --query Status --output text 2>/dev/null || true)
  [ "$s" = Success ] || [ "$s" = Failed ] && break; sleep 5
done
aws ssm get-command-invocation --region "$REGION" --command-id "$CMD" --instance-id "$IID" --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
