# cs2vpn

CS2 / FACEIT シンガポールサーバー向けの WireGuard 出口ノード (AWS ap-southeast-1)。3人で共有する。

## 使い方

```bash
export MSYS_NO_PATHCONV=1   # Git Bash の場合
# デプロイ (初回)
aws cloudformation deploy --region ap-southeast-1 --stack-name csvpn-sg \
  --template-file cfn/wg-exit.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides ClientNames=owner,mate1,mate2
scripts/fetch-configs.sh          # clients/*.conf を生成 (秘密鍵入り、git 管理外)
scripts/make-bundle.sh mate1      # bundles/mate1/ を作って本人に渡す
# 撤去
aws cloudformation delete-stack --region ap-southeast-1 --stack-name csvpn-sg
```

配布された側の手順は [docs/setup-guide.md](docs/setup-guide.md)。`start-tunnel.bat` を実行するだけ。宛先リストが更新されたときも同じ bat を再実行するだけでよい。

## ファイル

| パス | 役割 |
|---|---|
| `cfn/wg-exit.yaml` | CloudFormation。VPC、EC2 (WireGuard)、EIP、19:00〜02:00 JST の起動停止スケジュール |
| `dist/start-tunnel.{bat,ps1}` | クライアント起動スクリプト。最速経路のポートを選んで保存する |
| `scripts/` | 設定取得・split 反映 (apply-split)・計測・バンドル作成・check-tunnel (ルート検証) |
| `split-allowed-ips.txt` | split トンネルでシンガポール経由にする宛先。編集して push すれば、各自が `start-tunnel.bat` を再実行するだけで反映される (bat が GitHub から最新を取得) |
| `measurements/` | 計測ログ |

稼働中: スタック `csvpn-sg`、EIP `52.74.31.125`、UDP 51820。月およそ $7 (スケジュール停止込み)。
時間外に使う: `aws ec2 start-instances --region ap-southeast-1 --instance-ids <InstanceId>`。

背景や計測結果、設計判断は [CLAUDE.md](CLAUDE.md)。
