# PR #1 引き継ぎ

並行して追加された要件文書コミット `ef42111` を保持して統合する。

開始時の HEAD: `f906485aa3608b02f63da5ca7507a8bb6564f523`。

## 発見した不足と方針

- 相対ポインタの静止クリックとボタン解放が捨てられる。開始と終了も相対 HID で送る。
- GCKeyboard の短いキー入力で解放が抑制される。入力元と押下・解放を区別して重複を除く。
- ATS のローカル例外が全体例外を上書きする。MagicDNS の HTTP を許す設定に直す。
- 切断後に認証処理と古い WebSocket / WebRTC の callback が新しい接続を変更しうる。接続世代を検査し、処理をキャンセルする。
- F12 計測のローカル発光がない。送信に同期した 80 ms のマーカーを表示する。
- iOS は未コンパイル。Xcode 27.2 で依存 API とリンクを検証し、CI にも iOS ビルドを追加する。

元の `/Users/susumu/product/multikvm` は main、変更なし。専用コピーで作業する。
実機・VPN 設定は変更しない。実機接続、HHKB、AirPlay、50 ms は実測が必要。

## 検証記録

- `make ci_local`: 成功。Swift 27 件、Bun harness 102 件、依存監査、公開品質、textlint、lint を通過。既存の ESLint 警告 18 件は残る。
- `swift test --package-path ios`: WebRTC 156 のネイティブテスト 3 件成功。実 offer の H.264 High、packetization-mode、音声なし、RTP timestamp の保持を確認。
- Xcode 27.2: Simulator Debug のアプリとテストターゲット、および iphoneos Release を署名なしでビルド成功。
- 自動レビューの追加 3 件も修正。低速スクロールの端数を累積し、fallback 開始後の遅い LAN 候補も処理する。H.264 の局所的なフレーム欠落では表示を初期化し、キーフレームを要求して IDR から再開する。
- 独立レビューで 7 件を発見し、修正後の再レビューで解消を確認。追加でカーソル位置の保持と HTTP redirect 拒否を確認。
- 起点の CI は Ubuntu 26.04 で libxml2 の導入に失敗していた。Swift 用ランナーを配布物と同じ Ubuntu 24.04 に固定。
- 既存 Tailscale は Running、JetKVM 候補 1 台がオンライン。GET `/device` は 401。パスワードを取得せず、ログインと HID は未実施。

## 実機確認と環境の制約

- ローカルの CoreSimulator 1174.9.2 と Xcode 要求 1174.21.0 が不整合。シミュレータの起動と UI 操作は未実施。システムの更新は行わない。
- 接続ライフサイクルの iOS XCTest 4 件を追加。初回更新の CI（run 41094802654）で全件成功。ローカルではコンパイルのみ。
- 実機 iPhone への署名・インストール、認証後の Cookie と映像、Tailscale host ICE、HHKB、トラックパッド、AirPlay、50 ms の遅延は未確認。
- 実機のローカルパスワードは利用者がアプリへ直接入力する。秘密値をファイルや作業ログへ渡さない。
- マージ・配布・VPN 設定変更は行わない。
