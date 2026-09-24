#!/usr/bin/env bash
# Pull generated client configs from the exit node via SSM and set the Elastic IP as endpoint.
# Usage: scripts/fetch-configs.sh [stack-name] [region]
set -euo pipefail
export MSYS_NO_PATHCONV=1
STACK=${1:-csvpn-sg}; REGION=${2:-ap-southeast-1}
cd "$(dirname "$0")/.."
IID=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
EIP=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" --query 'Stacks[0].Outputs[?OutputKey==`PublicIp`].OutputValue' --output text)
CMD=$(aws ssm send-command --region "$REGION" --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /etc/wireguard/clients && for f in *.conf; do echo \"=====FILE $f\"; sudo cat $f; done"]' \
  --query Command.CommandId --output text)
for _ in $(seq 1 30); do
  s=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD" --instance-id "$IID" --query Status --output text 2>/dev/null || true)
  [ "$s" = Success ] && break; [ "$s" = Failed ] && { echo "ssm failed"; exit 1; }; sleep 3
done
mkdir -p clients && cd clients
aws ssm get-command-invocation --region "$REGION" --command-id "$CMD" --instance-id "$IID" --query StandardOutputContent --output text > _raw.txt
awk '/^=====FILE /{f=$2; next} {print > f}' _raw.txt && rm _raw.txt
sed -i "s/^Endpoint = .*/Endpoint = ${EIP}:51820/" ./*.conf
cd .. && scripts/fill-split.sh
ls -1 clients
