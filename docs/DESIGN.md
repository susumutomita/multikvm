# MultiKVM 設計

要件は [REQUIREMENTS.md](./REQUIREMENTS.md) に分けてあります。この文書は、その要件に対する設計判断です。

個人用の IP-KVM ビューアです。会社管理の Windows PC には何も入れず、自宅ルータ上の JetKVM から、Tailscale 経由の iPhone で映像と HID だけを扱います。

調査した JetKVM ファームウェアは `d646be873a136f1d7c2ec743e6fe826e43c65b30`（2026-10-30、`build: allow releasing from a branch other than dev`）です。計測値は実機が無いので載せていません。ソースから読めたことと、実機が必要なことを分けて書きます。

## ユースケース

操作される側は、自宅に置いた会社管理の Windows PC です。EDR があるため、キャプチャソフトは入れません。HDMI 入力と USB HID ガジェットを持つ IP-KVM を自宅ルータに置き、会社ネットワークには載せません。

操作する側は iPhone です。宅外からは Tailscale で自宅の JetKVM に届きます。入力は iPhone にペアリングした Bluetooth の HHKB Hybrid とトラックパッドです。iPhone の画面を外部ディスプレイへミラーしてもよいです。

今回作るのは、この経路のビューアとコントローラだけです。2 台切り替えと、内容を含まない通知は設計だけ残し、実装しません。

## 構成

```text
Windows PC --HDMI--> JetKVM --USB HID--> Windows PC
                         |
                    自宅ルータ
                         |
                     Tailscale
                         |
              iPhone (MultiKVM.app)
                 HHKB / トラックパッド
```

最初に対応する箱は、未改造の JetKVM です。オープンソースの Go ファームウェアで、RV1106 のハードウェア H.264 エンコーダを使います。遅延の主因が箱だと分かったときだけ、RK3588（ROCK 5B）の自作箱を検討します。今回は自作箱を作りません。

公開クライアントは iOS 17 の SwiftUI アプリです。プロトコルの純粋な部分は Swift パッケージ `MultiKVMCore` に置き、Linux の `swift test` で検証します。映像のデコードと WebRTC は iOS 側だけにあります。

## JetKVM が外に出すもの

未改造ファームウェアに、生の RTP や HTTP の H.264 口はありません。映像はローカルソケットの長さ付きフレームを `TrackLocalStaticSample` に載せ、WebRTC でのみ出ます。該当箇所は `internal/native/proxy.go` と `native.go` の `OnVideoFrameReceived` です。

シグナリングはローカル WebSocket `GET /webrtc/signaling/client` です（`web.go` の `handleLocalWebRTCSignal`）。手順は次のとおりです。

1. ソケットを開くと、機器が `{"type":"device-metadata","data":{"deviceVersion":...}}` を送る。
2. クライアントがオファー側である。`{"type":"offer","data":{"sd":"<base64>"}}` を送る。中身は `{type,sdp}` の JSON を Base64 したものである。
3. 機器は `{"type":"answer","data":"<base64>"}` を返す。オファーの `data` はオブジェクト、アンサーの `data` は文字列で、形が非対称である。
4. ICE は `{"type":"new-ice-candidate","data":{candidate,sdpMid,sdpMLineIndex}}` である。
5. テキスト `ping` には `pong` が返る。別セッションがいるときは `other-session-connected`、または close code `4001` である。

認証は、`LocalAuthMode` が `noPassword` でなければ `protectedMiddleware` が Cookie `authToken` を見ます。Cookie は `POST /auth/login-local` の `{"password":...}` で付きます。`GET /device` は保護され、未認証なら 401 です。`GET /device/status` は公開です。アプリはエフェメラルな `URLSession` に Cookie を留め、パスワードは保存しません。

ローカル経路（`IsCloud == false`）の ICE サーバは空です。STUN も TURN も使いません。クラウド UI（`ui` の `devices.$id.tsx`）は `CLOUD_API` から `webrtc/ice_config` と `turn_activity` を取ります。宅外で遅い、という体感と一致する経路はこちらです。オフィス LAN が速いのも、TURN を通さないローカル経路だから、とソース上は説明できます。所有者の回線での実測はこれからです。

Pion は全インタフェースの host 候補を集めます。JetKVM の Tailscale は Go の userspace netstack ではなく、システムの `tailscale` CLI です（`internal/tailscale/tailscale.go`）。`tailscaled` が上がっていれば、`tailscale0` の 100.64.0.0/10 が host 候補に出るはずです。iPhone 側の WebRTC が utun の Tailscale アドレスを候補に出すかは、実機で確認します。

コーデックは、オファーが H.265 を宣伝しなければ H.264 です（`webrtc.go` の `resolveCodec`）。エンコーダは High プロファイル、VBR、GOP はおおよそ fps の半分（約 0.5 秒）、`quality_factor` は固定です。REMB も TWCC もエンコーダのビットレートには戻していません。ビットレートが経路に追従しない、という仮説はソースで確認できました。GOP の長さは定常遅延ではなく、ロスからの復帰時間に効きます。

`playout-delay` 拡張（`internal/playoutdelay`）は、オファーが `http://www.webrtc.org/experiments/rtp-hdrext/playout-delay` を交渉したときだけ min=max=0 を刻みます。`webrtc.go` のコメントは、Chrome のジッタバッファが一度上がると下がりにくく、音声との同期が映像を遅らせる、と書いています。クライアントは音声の m-line を出さず、この拡張を出します。フィールドトライアル `WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:0` は補助で、拡張の代わりにはしません。

データチャネルはクライアントがオファー前に作ります。公式 UI の順は `rpc`、`hidrpc`、`hidrpc-unreliable-ordered`、`hidrpc-unreliable-nonordered` です。`terminal`、`serial`、`cdcacm`、`upload` は作りません。クリップボードもファイル転送もシリアルも使いません。

`rpc` は JSON-RPC 2.0 のテキストで、`params` はオブジェクトです。ホイールは HID の型 4 が定義されていますが、`handleHidRPCMessage` は処理しません。使うのはメソッド `wheelReport` の `{wheelY, wheelX}`（int8）です。ブラウザの `deltaY` 正（下）は、HID の正が上なので符号を反転します。

HID のバイナリは型バイトのあとがペイロードです。数値はバイト値の十進です。

| 型 | 名前 | ペイロード |
| --- | --- | --- |
| 1 | handshake | version 1。サーバが handshake を返す |
| 2 | keyboard | modifier とキー。ガジェットは 6 キーにパディングし、溢れると 1 を 6 個返す |
| 3 | pointer | int32 BE の x、y とボタン。絶対座標は 0 から 32767 |
| 6 | mouse | int8 の dx、dy とボタン |

ボタンは 1 が左、2 が右、4 が中です。修飾キーの usage 224 から 231 はビット 1、2、4、8、16、32、64、128 です。`keypress`（型 5）は 100 ms で自動リリースされ、50 ms ごとの keepalive（型 9）が要ります。フルの keyboard レポートは自動リリースしないので、こちらを送り、キー状態はクライアントが持ちます。絶対移動はボタンが変わったときだけ reliable、それ以外は unreliable-ordered です。相対移動は reliable で、int8 の範囲に分割します。

JIS と US の差は次のとおりです。円とバックスラッシュ（usage 137、International3）とろ（usage 135、International1）を相手レイアウトの usage 49 と 100 に寄せます。変換（usage 138）と無変換（usage 139）は US ホストでは捨てます。文字フォールバックでは、US の `@` は Shift と usage 31、JIS の `@` は無修飾の usage 47 です。HHKB のハードウェアキーは HID usage を優先し、文字は usage が無いときだけ使います。

## 未改造 JetKVM への最短経路

Tailscale のアドレスへローカル WebSocket だけを開きます。クラウド API は呼びません。オファーは H.264 だけで、音声は無く、`playout-delay` を付けます。ICE サーバは空です。

候補は次の順で絞ります。`typ relay` と `typ srflx` は捨てます。host 候補に Tailscale があれば（IPv4 は 100.64.0.0/10、第 2 オクテット 64 から 127。IPv6 は `fd7a:115c:a1e0:`）、それだけを出します。無ければ LAN の host を出します。ローカル候補はオファーを送るまで溜め、サーバがセッション無しで捨てるのを避けます。リモートの非 Tailscale 候補は約 400 ms 待ち、その間に Tailscale が来たら LAN は捨てます。

受信した H.264 は、WebRTC の描画ビューを使わず、`AVSampleBufferDisplayLayer` に `kCMSampleAttachmentKey_DisplayImmediately` で積めます。`isReadyForMoreMediaData` が false または表示失敗なら、表示を初期化してキーフレームを要求し、次の IDR から再開します。参照フレームを失った状態で後続の interframe を表示しません。SPS と IDR を見るまではデコード結果 4（キーフレーム要求）を返します。High プロファイルをデコードできることが条件です。デコーダのコールバックを空のままにすると受信パイプラインがフレームを抱えることがあるので、幅 2 高さ 2 の空フレームで会計だけ返します。表示に使う画素はこちらです。

WebRTC の受信ジッタバッファはデコーダの前に残ります。`playout-delay` 0 は、JetKVM が Chrome と libwebrtc を 0 に固定するために既に使っている仕組みです。Safari は同じように扱いません。ネイティブの libwebrtc クライアントを選ぶ理由はここです。依存は stasel/WebRTC の exact `156.0.0`（revision `3cc466ea040e5dcd1344697bf211dc4c079d1a0c`、product 名 `WebRTC`）です。バイナリの XCFramework はリポジトリに同梱しません。チェックサムは上流 `Package.swift` の `43c2a6f7a650185bbc911d7605a979589671886e8fc0ac283f54fdf3f511dc46` です。

この経路でも、DTLS と SRTP と SCTP は残ります。遅延の本体はそこよりも、リレー、ブラウザのジッタバッファ、固定ビットレートだと判断しています。後者 2 つはソースと一致します。リレーはクラウド経路のコードと一致し、所有者の宅外経路が実際に TURN か DERP かを見るのは実測です。Tailscale 自体が DERP に落ちると、アプリからは外せません。

## ファームウェアを変えると買えるもの

未改造のままでは、ACL を 1 ポートにできません。シグナリングの TCP 80 と、エフェメラルな UDP が要ります。将来のファームウェアで意味があるのは次です。

- ICE の UDP を 1 ポートに束ね、ACL を TCP と UDP の決まった組にする。
- iPhone が utun の候補を出さないとき、`SetNAT1To1IPs` で Tailscale アドレスだけを host 候補にする。
- 長さ付き Annex-B をそのまま TCP か UDP で渡し、SRTP とジッタバッファを避ける。内部のネイティブソケットは既にリトルエンディアンの長さ付きフレームである。
- エンコーダを低遅延の CBR にし、TWCC の結果をビットレートへ戻す。
- DTLS 証明書を固定し、アプリがピンできるようにする。今の証明書はセッションごとに変わる。

DTLS の暗号コスト自体は、ガラスからガラスの 50 ms 予算の主因にはしない想定です。実測で覆ったら見直します。

## セキュリティ

到達性は Tailscale だけにします。例の ACL は、操作する iPhone のタグから JetKVM のタグへ、TCP 80 と UDP を許可し、Tailscale SSH は許可しません。Funnel と Serve は使いません。JetKVM のクラウドトークンは外し、クラウド UI からの TURN 設定を取りに行きません。管理画面をループバック以外へ広げる設定も外します。

未改造では UDP ポートがエフェメラルなので、「1 ポートだけ」は満たせません。許可するのは iPhone のタグから TCP 80 と、そのタグ発の UDP です。会社 PC から箱へは HDMI と USB だけで、IP では届かせません。

ペアリングは、利用者が `device-metadata` のバージョンを確認したあと、`scheme://host[:port]` を小文字で保存します。ホスト文字列が変わると、再確認するまで映像を始めません。パスワードは保存しません。暗号のピンは、証明書がエフェメラルなのでファームウェア待ちです。中は WebRTC の DTLS-SRTP と、その下の WireGuard です。ファームウェア無しの第二の E2E 層は足しません。

アプリは `UIPasteboard` を読まず、録画もファイル転送もしません。`preventsCapture` は付けません。付けると AirPlay ミラーが止まり、外部ディスプレイの前提が壊れます。画面収録やスクリーンショットは OS が許す範囲で残ります。iOS が一部のショートカットを先に取ることも残ります。ATS は `NSAllowsArbitraryLoads` です。MagicDNS の HTTP は公開 CA の証明書を持たないためです。ダイヤルしてよいホストは、画面で設定したアドレスだけです。

## 遅延予算

目標はガラスからガラスで約 50 ms です。内訳の目安は次です。

| 区間 | 目安 | アプリが見るもの |
| --- | --- | --- |
| キャプチャとエンコード | 15 ms | ソースと iPhone を同じ LAN で比べた残り。エンコーダ時刻は外に出ない |
| ネットワーク片道 | 15 ms | WebRTC の `currentRoundTripTime` の半分。オーバーレイの RTT/2 |
| デコードと表示 | 15 ms | デコード完了後の enqueue 時間。ジッタバッファはここより前 |
| 入力 | 10 ms | キーを押してから、分配した HDMI の先の画面が変わるまで |

合計が 50 ms を超えても、どの区間が越えたかを先に見ます。計測手順は [latency.md](./latency.md) です。目標との差は [#5](https://github.com/susumutomita/multikvm/issues/5) で記録します。オーバーレイは fps、kbps、RTT/2、enqueue、破棄フレーム、経路、時計の下位ミリ秒を出します。経路と RTT は選択済みの ICE candidate pair から取得します。候補収集中は「候補」と表示し、Tailscale 内部の直接通信と DERP の区別はアプリから断定しません。

## 入力と外部ディスプレイ

キーボードは `UIKey` と `GCKeyboard` です。同じキーの同じ遷移が 50 ms 以内に別の入力元から来たら、重複だけを除きます。押下と解放を区別するので、短いタップの解放も送ります。HHKB の JIS と US、Windows の JIS と US を設定で選び、usage を変換します。ポインタは絶対と相対を切り替え、スクロールは `wheelReport` です。絶対座標は映像のレターボックスを除いた 0 から 1 を、0 から 32767 に写します。

外部ディスプレイは、iPhone の画面ミラー（AirPlay を含む）を前提にします。HHKB、トラックパッド、外部モニタの実機確認は [#4](https://github.com/susumutomita/multikvm/issues/4) です。専用の `UIWindow` は iOS 16 以降のシーン構成が増えるので、今回は作りません。バックグラウンドに入ると切断し、非アクティブではキーを離します。

## 今回は作らないもの

2 台の PC は、箱を 2 つと、保存するホスト文字列を配列にすることです。今の `pairedHost` は 1 本です。切り替え UI は次の変更で足します。2 台切り替えと内容を含まない通知の追跡は [#6](https://github.com/susumutomita/multikvm/issues/6) です。

通知は、映像の決まった領域が変化したかどうかの真偽だけを箱側で出し、文字も OCR もクラウドも載せない想定です。内容が要る通知は作りません。実装はファームウェアと一緒に後です。

RK3588 の自作箱は、未改造 JetKVM とこのクライアントで 50 ms に届かないと分かってから設計します。先に生の Annex-B を足す方が、基板を変えるより小さいです。

## 検証の境界

Linux で `swift test` したのは、シグナリングの JSON、ICE の Tailscale 選別、接続フェーズ、HID レポート、JIS 変換、H.264 の depacketize、SDP の `playout-delay`、バーコードの往復です。

iOS アプリは Xcode 27.2 でシミュレータ向けと実機向けの署名なしビルドを確認しました。WebRTC 156 の offer 生成とデコーダの時刻は macOS のネイティブテストでも検証します。実機の ICE、HHKB、パスワード Cookie、ミラーは、JetKVM と iPhone が必要です。実機ビルドは [#2](https://github.com/susumutomita/multikvm/issues/2)、宅外の直結経路は [#3](https://github.com/susumutomita/multikvm/issues/3) です。詳細は [latency.md](./latency.md) と README の未検証一覧です。
