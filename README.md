# MultiKVM

自宅の JetKVM を、Tailscale 上の iPhone から見るための個人用 IP-KVM です。会社管理の Windows PC にはソフトウェアを入れません。映像とキーボード、ポインタだけを扱い、クリップボード、ファイル転送、録画はしません。

要件は [docs/REQUIREMENTS.md](./docs/REQUIREMENTS.md) です。設計の正本は [docs/DESIGN.md](./docs/DESIGN.md) です。遅延の測り方は [docs/latency.md](./docs/latency.md) です。

## 何が動くか

Linux でテストしているのは、JetKVM のローカル WebRTC シグナリング、ICE 候補の選別、HID レポート、JIS と US の変換、H.264 の分割、SDP の検査です。iOS アプリのソースは同梱しています。このリポジトリの CI は Linux だけで、iPhone 向けバイナリは作っていません。

## iPhone で開く

Xcode 16 以降で `ios/MultiKVM.xcodeproj` を開きます。署名チームを自分の Apple ID にし、iOS 17 の実機へ入れます。シミュレータでは Tailscale の utun とハードウェアキーボードを確認できません。

接続先には、JetKVM の Tailscale 名か 100.64.0.0/10 のアドレスを入れます。`http://` は省略できます。初回は機器のバージョンを確認してから映像が始まります。ローカルパスワードはメモリだけに置き、保存しません。

キーボード欄は、HHKB の配列と Windows の配列です。一致しているときは変換しません。ポインタは絶対と相対を切り替えます。オーバーレイに fps、ビットレート、RTT の半分、表示へ渡した時間、破棄数、経路、時計が出ます。

JetKVM 側ではクラウド機能を切り、Tailscale SSH を許可せず、アプリからはローカルの WebSocket だけを使います。ACL の例と、未改造では UDP を 1 ポートにできない理由は設計文書にあります。

## 遅延を測る

Windows で `tools/latency/clock.html` を開きます。手順は [docs/latency.md](./docs/latency.md) です。

## 開発

プロトコルテストは Swift 6.2 です。

```bash
swift test --package-path swift
```

リポジトリには、派生元テンプレートのサプライチェイン検査も残しています。文書と TypeScript の検査は Bun です。

```bash
make install
make before-commit
make ci_local
```

`make ci_local` は Bun の検査に加え、`swift test` を走らせます。Swift が PATH に無いと失敗します。GitHub Actions の `swift` ジョブは、Swift 6.2 の Ubuntu 24.04 アーカイブをチェックサム付きで展開してから同じテストを走らせます。

## 未検証

次は JetKVM と iPhone が無いと確認できません。

- iOS アプリが Xcode でコンパイルできること。WebRTC 156 の型名はヘッダをこの環境でビルドしていない。
- iPhone が Tailscale の host 候補を出すこと。出さない場合、ファームウェア側の候補固定が要る。
- `playout-delay` と空の ICE で、宅外の直接経路がリレーより短くなること。
- HHKB Hybrid の JIS キー、修飾キー、トラックパッドのスクロール。
- ローカルパスワードの Cookie と、別セッションの拒否。
- AirPlay ミラー中に映像が黒くならないこと。
- ガラスからガラスが約 50 ms に収まること。

## ライセンス

MIT です。WebRTC の XCFramework はアプリのビルド時に stasel/WebRTC `156.0.0` から取得し、このリポジトリには入れません。
