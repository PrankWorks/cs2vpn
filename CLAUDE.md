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
| OVH エッジ 103.5.15.5 (登録上は香港 OVH-VKS-HKG2) / SG LG 15.235.182.181 | 94〜135 ms | KDDI → Telstra 134.159.125.37 (118ms) → PCCW 202.84.x (190ms 超のホップ) → OVH |
| Leaseweb SG 23.106.253.x | 81 ms | KDDI → Tata 216.6.52.5 (東京) → Tata SG |
| SG.GS 103.14.247.x | 94 ms | Tata 経由 |
| GCP asia-southeast1 35.240.144.156 | 86 ms | KDDI → Google 直接ピア |
| Valve SDR "sgp" 103.10.124.116 | 100 ms | Telstra/PCCW 経由 |
| AWS ap-southeast-1 (EIP) | 82〜93 ms | 4ホップ目で AWS 網 |
| AWS ap-southeast-1 IPv6 | 93 ms | Equinix 経由。IPv4 より劣るので IPv4 エンドポイントを採用 |
| AWS ap-northeast-1 | 14 ms | 東京入り + AWS バックボーン 76ms ≒ 90ms で利点なし。比較用の東京スタックは削除済み |

出口ノード → OVH SG / Valve SDR sgp / GCP SG / Leaseweb SG はいずれも 1〜2 ms。

夜 (2026-09-24 20:00〜20:30 JST、直結) に各社のシンガポール公開 ping ホストを測った結果。昼より KDDI のトランジット経由 (Telstra/PCCW/NTT) が大きく悪化する一方、直接ピアしている網は変わらない:

| 事業者 (SG) | 夜の直結 RTT | 経路 |
|---|---|---|
| Linode/Akamai 139.162.23.4 | 82 ms (2回とも) | Akamai 網 104.74.x 経由。最良 |
| GCP 35.240.144.156 | 87〜88 ms | Google 直接ピア |
| AWS EIP 52.74.31.125 | 94 ms (昼は 82〜88) | 4ホップ目で AWS 網 |
| OVH 15.235.182.181 | 144〜157 ms (昼は 94〜100) | Telstra/PCCW |
| Hetzner 5.223.7.195 | 156〜165 ms | NTT 129.250.x 経由 |
| Vultr 45.32.100.168 | 190 ms | |
| Leaseweb 103.254.153.18 / 23.106.253.161 | 183〜206 ms / 90% ロス (昼は 81 ms) | Tata 経由が夜に崩れる |
| Hostens 212.237.232.111 | 279 ms | |

含意: 「ラグい」の正体は夜間に KDDI のトランジット経路が劣化することで、FACEIT サーバーがその経路上 (OVH/Leaseweb 系) にあれば夜は 150ms 超もあり得る。出口候補としては Linode Singapore (Akamai 経由 82ms) が AWS より 12ms 速く、時間帯でも崩れていない。DigitalOcean の公開ホストは名前解決できず未計測。

自宅側 13〜14ms は v6プラスのアクセス網の固定費、東京〜シンガポールは物理距離で 65〜70ms が下限。トンネル経由 (87〜93ms) はほぼ天井で、残る改善余地は別事業者の SG リージョンを試す数 ms 程度。

**重要な留保**: 所有者が直結で FACEIT SEA をプレイしたときの TAB ping は 77〜95ms。実際に当たっている FACEIT サーバーは OVH ではなく Leaseweb/GCP 相当の経路にいる可能性が高く、その場合トンネルは平均 ping を改善しない (むしろ数 ms 悪化)。トンネルの価値は「宛先によらず 88〜93ms に揃う」「PCCW 区間の揺れを避ける」安定性側にある。続ける価値の判断には、試合ごとのサーバー IP と TAB ping を直結/トンネルで比較する実データが要る (未収集)。

## ECMP 問題と start-tunnel.ps1

- KDDI ↔ AWS SG 間で UDP フローが 5タプルハッシュで複数経路に分散され、送信元ポートによって 86〜100ms の経路か 233〜261ms の経路に乗る。外れ率は測定回によって 2/16〜5/13。
- 初回トンネル接続時に 247ms を引いて発覚。サーバー側処理は tcpdump で 0.15ms、NordVPN 停止でも不変、生 UDP でポートを変えると再現、で切り分けた。
- 対策は `dist/start-tunnel.ps1` (管理者権限)。トンネルを張ったまま `wg set <name> listen-port <p>` で候補ポートを切り替え、10.66.0.1 への ping 最小値を比べて最速ポートを conf に保存する。再起動後に再検証し、150ms 以上なら次点に切り替える。
- MAP-E の外向きポート割当は接続ごとに少し変わるため、計測時 85ms のポートが再起動後 92ms になる程度のぶれはある。良い経路群の中でのぶれなので許容。
- `wireguard.exe /installtunnelservice <任意パス>` だけだと WireGuard アプリの一覧に出ない。アプリは `C:\Program Files\WireGuard\Data\Configurations` の `.conf.dpapi` しか見ないので、start-tunnel.ps1 は平文 conf をそこに置き、WireGuardManager サービスを再起動して暗号化させ、`.conf.dpapi` からサービスを起動している。
- アプリの保存先にある旧 `.conf.dpapi` は WireGuardManager を止めただけでは削除できず (UI プロセスが握っている)、旧 AllowedIPs のまま起動してしまう事故があった (2026-09-24 夜、PhoenixNAP の CIDR を足したのに載らなかった)。start-tunnel.ps1 は wireguard.exe を全部止めて takeown/icacls で消し、起動後に AllowedIPs の各 CIDR が Get-NetRoute に載っているか検証して警告する。
- 夜間はサービス再起動のたびに外れ経路 (250ms) を引くことが続いた (6回連続) ため、最終起動後に RTT が悪ければ再起動せず `wg set listen-port` を回して良い経路に落ち着かせ、その時のポートを conf に書く。
- **何が「効いている設定」か (2026-09-25 再調査)**: トンネルサービスのバイナリパスは `/tunnelservice "C:\Program Files\WireGuard\Data\Configurations\<name>.conf.dpapi"` で、有効なのはアプリ保存先の暗号化コピーだけ。`clients/*.conf` や `bundles/` の conf を編集しても、start-tunnel.ps1 で再登録するか GUI で再インポートするまで何も変わらない。GUI の「編集」で保存した内容はアプリが再暗号化して即反映する (GUI 上の AllowedIPs = 実際に効いている AllowedIPs)。
- 2026-09-25 00:05 に登録し直した直後は 91 ルートを確認したのに、00:35 の時点でカーネルの AllowedIPs が初期リストの 11 件に戻っていた。ログにはその間のトンネル再起動が無く、原因は特定できていない (GUI での再インポート/編集、または保存先の再暗号化時に古い内容が使われた可能性)。`scripts/check-tunnel.ps1` (非管理者で実行可) が conf とルートの差分を出すので、プレイ前に確認する。差分があれば start-tunnel.ps1 で再登録する。
- 2026-09-25: start-tunnel.ps1 は起動時に GitHub の raw `split-allowed-ips.txt` (master) を取得し、split conf の AllowedIPs を `10.66.0.0/24 + リスト` で書き換えてから登録する (`-NoUpdate` で抑止、full conf は対象外、取得失敗時は現状維持)。したがって宛先追加の手順は「リストを編集 → commit & push → 各自が bat を再実行」。配布済みバンドルの再配布は不要。scripts/apply-split.sh はオフライン用/バンドル再生成用。
- `wg set <name> peer <pub> allowed-ips ...` はカーネル側の AllowedIPs には即時に効くが、Windows のルートは追加されない (実験済み: 192.0.2.0/24 を足しても Find-NetRoute は物理 NIC を返す) ので、動的追加には New-NetRoute も必要。再起動すると保存先の内容に戻る。
- 所有者の PC では所有者用の full conf がアプリに登録済み (2026-09-24 時点、ポート 42381)。full は全通信を通すので、ノードが 02:00 に停止すると WireGuard を無効化するまでネット全体が落ちる。普段は split を推奨。

## FACEIT サーバー IP について

- FACEIT は SGP サーバーの IP を公開しておらず、監視サイトにも載らない (A2S に応答しない)。旧 Steam マスターサーバー (hl2master) は廃止済み。
- FACEIT 内部 API (`api.faceit.com/match/v2/match/<id>`、ブラウザのログインセッションで叩ける) は終了済み試合にサーバー IP を含まない (location "Singapore" のみ)。IP は試合中にしか取れない。
- コミュニティ報告の候補: OVH 139.99.112.177 / 51.79.176.5、SG.GS 103.14.247.211/.203、Leaseweb 23.106.253.161、GCP 35.240.144.156 / 35.187.231.7。これらの網を `split-allowed-ips.txt` に入れてある。
- **訂正**: 131.153.46.204:27015 (PhoenixNAP Singapore, AS59210) は所有者が servers.upkk.com のサーバー一覧で見つけたシンガポールのコミュニティサーバーで、**FACEIT のサーバーではない**。以下はこのコミュニティサーバーに対する計測。A2S に challenge 応答あり。自宅からは KDDI → NTT 129.250.x → 116.51.16.243 → PhoenixNAP エッジ 103.243.172.31 で 81〜82 ms (夜でも安定、サーバー自体は ICMP 無応答)。EC2 → 同サーバー 1.3〜2.3 ms。つまり夜の AWS 経由は 94+2 ≒ 96 ms で直結より約 12 ms 遅く、この事業者に対してはトンネルの利点がない (ただし FACEIT がここを使っている証拠はない)。split-allowed-ips.txt には有効な CIDR として記載 (所有者の方針: リストには入れておき、直結のほうが良い日はトンネルを切るだけ)。このコミュニティサーバーでは直結のほうがゲーム内 ping が良かった (2026-09-24 夜、トンネル経由 79+2ms の見込みに対して)。OVH/Leaseweb 系のサーバーに当たった試合だけトンネルが効く構図。
- servers.upkk.com (country=SG) のコミュニティサーバー 122 本は 11 ホストに集約され、Datacamp/CDN77 (149.102.250.x) が 111 本、他は OVH、PhoenixNAP、Vultr、GSL Networks、Hetzner。2026-09-24 にこれらの SG ブロックをすべて split-allowed-ips.txt に追加 (計 58 CIDR)。ただしこれは FACEIT のサーバーではなく「シンガポール所在のサーバー網の網羅」であり、FACEIT SGP の実 IP は依然未確認。
- **確定 (2026-09-24 夜、FACEIT の実試合)**: FACEIT SGP ゲームサーバー 79.127.213.54 = Datacamp/CDN77 Singapore (AS60068、ブロック 79.127.213.0/24)。サーバーは ICMP に応答する。自宅直結: KDDI → Datacamp 網 138.199.0.36 (東京、13ms) → 152.233.118.1 (79ms) → SG で 92 ms。EC2 → 同サーバー 1.5 ms。したがってトンネル経由は 80〜85 + 1.5 ≒ 82〜87 ms の見込みで、直結 92 ms より 5〜10 ms 改善。Datacamp のシンガポール割当は RIPE (netname CDN77-SGP / CDNEXT-SGP、21 レンジ) と ARIN (CDNEXT-SGP*、11 レンジ) に分かれており、合計 32 CIDR をすべて split-allowed-ips.txt に入れた (/24 だけでは不足)。Datacamp は servers.upkk.com の SG コミュニティサーバーの大半 (149.102.250.x) も抱えており、FACEIT SEA が Datacamp を使っている可能性が高い。
- 2026-09-26: RIPE にはアンダースコア表記の netname (CDN77_SGP / CDN77_SGP-EQ3 / CDN77_SGP_EQ3) もあり、ハイフン表記の検索では漏れていた 84.17.38.0/23、89.187.162.0-239 + 89.187.163.0/24、143.244.33.0/24、169.150.243.0/24 を追加 (RIPE 上の Datacamp SGP 登録 26 件はこれで全部載った)。89.187.162.240/28 は BUNNYCDN_SGP (Datacamp 上の CDN 顧客) なので除外。Datacamp の別 AS (AS212238) の SG 範囲は顧客のリース IP (VPN 業者など) なので入れていない。
- **リストの追加方針 (所有者、2026-09-26)**: 「確実にシンガポール」かつ「FACEIT が使っている確証がある」網だけ追加する。現時点で確証があるのは Datacamp/CDN77 だけ。Vultr SG (公式 geofeed で 16 プレフィクス)、Leaseweb SG (LSW-SG* 14 ブロック)、SG.GS の残りは SG であることは確認済みだが FACEIT の確証がないので保留。誤ったエントリーは消す: 2026-09-26 に 103.5.12.0/22 (登録は OVH 香港 OVH-VKS-HKG1/2) を削除、139.99.0.0/16 を 139.99.0.0/17 に縮小 (139.99.128.0/17 は OVH Australia)。
- 実 IP の確認手段: 試合中に CS2 コンソールで `status` (`udp/ip` 行)。自動化するなら起動オプション `-condebug` で `game/csgo/console.log` を出し、接続行を監視する。所有者の現在の起動オプションに `-condebug` は入っていない。

## 環境の癖

- Windows + Git Bash。`aws ssm` の `/aws/service/...` などスラッシュ始まりの引数は MSYS がパス変換して壊すので `MSYS_NO_PATHCONV=1` を付ける。
- Windows の tracert は ICMP。KDDI/JPNE 側は ICMP に応答するが、宛先によっては途中ホップが無応答。
- 管理者権限が必要な操作 (WireGuard のサービス登録、`wg.exe`) は `Start-Process powershell -Verb RunAs` で UAC を出す。シェル自体は非管理者。
- 所有者の PC には NordVPN が常駐しているが、干渉しないことは確認済み。
- Steam の CS2 は `C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive`。

## 費用 (ap-southeast-1 単価)

EC2 t4g.micro $0.0106/h、EBS gp3 8GB $0.77/月、パブリック IPv4 $0.005/h (停止中も課金)、送信転送は月 100GB まで無料、以降 $0.12/GB。24 時間稼働で約 $12/月、19:00〜02:00 稼働で約 $6.7/月。CS2 は 1人 1時間あたり約 200MB。
