# CLAUDE.md

このリポジトリで作業する Claude 向けの背景知識。README は最小限にしてあるので、経緯・計測値・判断理由はここに置く。

## 目的と現状

- 目的: 自宅 (東京、KDDI / v6プラス MAP-E) から FACEIT シンガポール (SEA) サーバーへの経路を、AWS ap-southeast-1 の WireGuard 出口ノード経由に置き換え、3人 (所有者 + 友人2人) で共有する。
- 稼働中: CloudFormation スタック `csvpn-sg` (ap-southeast-1)、EIP 52.74.31.125、UDP 51820、トンネル網 10.66.0.0/24 (サーバー .1、クライアント .11〜.13)。
- スタックのパラメータ ClientNames は作成時の値のままで、現在のクライアント名 (clients/ のファイル名) とは一致しない。2026-09-24 に各人の名前へリネームしたが、鍵はそのままでファイル名とサーバー側コメントを付け替えただけ。**パラメータを変えると UserData が変わりインスタンスが再作成され、鍵と EIP が変わる**ので触らない。
- EventBridge Scheduler で毎日 19:00 JST 起動 / 02:00 JST 停止。停止/起動で EIP・IPv6・鍵は保持され、wg-quick@wg0 は自動起動。停止→起動の一巡は 2026-09-24 時点で未検証。
- 公開リポジトリ: https://github.com/PrankWorks/cs2vpn (origin は HTTPS、ブランチ master)。秘密鍵入りの `clients/`、`bundles/`、`*.conf` は .gitignore 済み。public なので自宅 IP・AWS アカウント ID・インスタンス ID・鍵・各人のハンドル名を書かないこと (クライアント名は owner/mate1/mate2 などの汎用名で表記する)。

## 構成の要点

- EC2 は t4g.micro (AL2023 arm64、カーネル WireGuard)。専用 VPC 10.99.0.0/24 (IPv6 付き)。SSH は開けておらず、操作はすべて SSM (`aws ssm send-command`) で行う。
- 初回起動の UserData がサーバー鍵と ClientNames 分のピア鍵・クライアント設定 (`/etc/wireguard/clients/<name>-{full,split}.conf`) を生成する。split の AllowedIPs は `__SPLIT_ALLOWED_IPS__` のままなので、`scripts/fetch-configs.sh` が取得後に EIP と `split-allowed-ips.txt` の CIDR を埋める。
- UserData が読む public-ipv4 は起動直後の自動割当 IP で EIP ではない。fetch-configs.sh が Endpoint を EIP に書き換えるのはそのため。
- 帯域・CPU は 3人分のゲーム通信 (合計 2Mbps 弱) に対して十分。実測で CPU 3%、メモリ 156MB/916MB。full トンネルで大容量ダウンロードをするとバースト枠を使い切って 64Mbps に制限され、同時プレイ中の人にジッタが出うる。

## 計測で分かったこと (2026-09-24)

自宅 → 各拠点 (直結、ICMP):

| 宛先 | RTT | 経路 |
|---|---|---|
| OVH SG エッジ 103.5.15.5 / LG 15.235.182.181 | 94〜135 ms | KDDI → Telstra 134.159.125.37 (118ms) → PCCW 202.84.x (190ms 超のホップ) → OVH |
| Leaseweb SG 23.106.253.x | 81 ms | KDDI → Tata 216.6.52.5 (東京) → Tata SG |
| SG.GS 103.14.247.x | 94 ms | Tata 経由 |
| GCP asia-southeast1 35.240.144.156 | 86 ms | KDDI → Google 直接ピア |
| Valve SDR "sgp" 103.10.124.116 | 100 ms | Telstra/PCCW 経由 |
| AWS ap-southeast-1 (EIP) | 82〜93 ms | 4ホップ目で AWS 網 |
| AWS ap-southeast-1 IPv6 | 93 ms | Equinix 経由。IPv4 より劣るので IPv4 エンドポイントを採用 |
| AWS ap-northeast-1 | 14 ms | 東京入り + AWS バックボーン 76ms ≒ 90ms で利点なし。比較用の東京スタックは削除済み |

出口ノード → OVH SG / Valve SDR sgp / GCP SG / Leaseweb SG はいずれも 1〜2 ms。

自宅側 13〜14ms は v6プラスのアクセス網の固定費、東京〜シンガポールは物理距離で 65〜70ms が下限。トンネル経由 (87〜93ms) はほぼ天井で、残る改善余地は別事業者の SG リージョンを試す数 ms 程度。

**重要な留保**: 所有者が直結で FACEIT SEA をプレイしたときの TAB ping は 77〜95ms。実際に当たっている FACEIT サーバーは OVH ではなく Leaseweb/GCP 相当の経路にいる可能性が高く、その場合トンネルは平均 ping を改善しない (むしろ数 ms 悪化)。トンネルの価値は「宛先によらず 88〜93ms に揃う」「PCCW 区間の揺れを避ける」安定性側にある。続ける価値の判断には、試合ごとのサーバー IP と TAB ping を直結/トンネルで比較する実データが要る (未収集)。

## ECMP 問題と start-tunnel.ps1

- KDDI ↔ AWS SG 間で UDP フローが 5タプルハッシュで複数経路に分散され、送信元ポートによって 86〜100ms の経路か 233〜261ms の経路に乗る。外れ率は測定回によって 2/16〜5/13。
- 初回トンネル接続時に 247ms を引いて発覚。サーバー側処理は tcpdump で 0.15ms、NordVPN 停止でも不変、生 UDP でポートを変えると再現、で切り分けた。
- 対策は `dist/start-tunnel.ps1` (管理者権限)。トンネルを張ったまま `wg set <name> listen-port <p>` で候補ポートを切り替え、10.66.0.1 への ping 最小値を比べて最速ポートを conf に保存する。再起動後に再検証し、150ms 以上なら次点に切り替える。
- MAP-E の外向きポート割当は接続ごとに少し変わるため、計測時 85ms のポートが再起動後 92ms になる程度のぶれはある。良い経路群の中でのぶれなので許容。
- `wireguard.exe /installtunnelservice <任意パス>` だけだと WireGuard アプリの一覧に出ない。アプリは `C:\Program Files\WireGuard\Data\Configurations` の `.conf.dpapi` しか見ないので、start-tunnel.ps1 は平文 conf をそこに置き、WireGuardManager サービスを再起動して暗号化させ、`.conf.dpapi` からサービスを起動している。
- 所有者の PC では所有者用の full conf がアプリに登録済み (2026-09-24 時点、ポート 42381)。full は全通信を通すので、ノードが 02:00 に停止すると WireGuard を無効化するまでネット全体が落ちる。普段は split を推奨。

## FACEIT サーバー IP について

- FACEIT は SGP サーバーの IP を公開しておらず、監視サイトにも載らない (A2S に応答しない)。旧 Steam マスターサーバー (hl2master) は廃止済み。
- FACEIT 内部 API (`api.faceit.com/match/v2/match/<id>`、ブラウザのログインセッションで叩ける) は終了済み試合にサーバー IP を含まない (location "Singapore" のみ)。IP は試合中にしか取れない。
- コミュニティ報告の候補: OVH 139.99.112.177 / 51.79.176.5、SG.GS 103.14.247.211/.203、Leaseweb 23.106.253.161、GCP 35.240.144.156 / 35.187.231.7。これらの網を `split-allowed-ips.txt` に入れてある。
- 実 IP の確認手段: 試合中に CS2 コンソールで `status` (`udp/ip` 行)。自動化するなら起動オプション `-condebug` で `game/csgo/console.log` を出し、接続行を監視する。所有者の現在の起動オプションに `-condebug` は入っていない。

## 環境の癖

- Windows + Git Bash。`aws ssm` の `/aws/service/...` などスラッシュ始まりの引数は MSYS がパス変換して壊すので `MSYS_NO_PATHCONV=1` を付ける。
- Windows の tracert は ICMP。KDDI/JPNE 側は ICMP に応答するが、宛先によっては途中ホップが無応答。
- 管理者権限が必要な操作 (WireGuard のサービス登録、`wg.exe`) は `Start-Process powershell -Verb RunAs` で UAC を出す。シェル自体は非管理者。
- 所有者の PC には NordVPN が常駐しているが、干渉しないことは確認済み。
- Steam の CS2 は `C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive`。

## 費用 (ap-southeast-1 単価)

EC2 t4g.micro $0.0106/h、EBS gp3 8GB $0.77/月、パブリック IPv4 $0.005/h (停止中も課金)、送信転送は月 100GB まで無料、以降 $0.12/GB。24 時間稼働で約 $12/月、19:00〜02:00 稼働で約 $6.7/月。CS2 は 1人 1時間あたり約 200MB。
