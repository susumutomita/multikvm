# Security Policy

## サポート対象

MultiKVM は個人用の IP-KVM ビューアです。最新の `main` ブランチだけをサポートします。JetKVM 本体の脆弱性は上流へ報告してください。

## 脆弱性の報告

セキュリティ上の問題を見つけた場合は、公開の Issue で開示せず、次のいずれかで連絡してください。

- GitHub の [Private vulnerability reporting](https://github.com/susumutomita/multikvm/security/advisories/new) を使う（推奨）
- メール: `oyster880@gmail.com`

48 時間以内に受領確認を返します。修正方針と公開時期は、必要であれば調整可能なリードタイムで合意します。

## このアプリが守る境界

到達先は利用者が入れた Tailscale 上の JetKVM だけです。クラウド API は呼びません。パスワード、クリップボード、録画ファイルは保存しません。認証 Cookie はプロセス内のエフェメラルセッションにだけ置きます。

未改造の JetKVM では、シグナリングの TCP と映像の UDP を 1 つのポートへまとめられません。ACL、Tailscale SSH の無効化、クラウド機能の停止は運用手順です。詳細は [docs/DESIGN.md](./docs/DESIGN.md) です。

## サプライチェイン防御の前提

派生元の検査は残しています。設計判断と invariant の詳細は次です。

- [ADR-0001: サプライチェイン攻撃への多層防御を既定にする](./docs/adr/0001-supply-chain-hardening.md)
- [docs/architecture/harness.md](./docs/architecture/harness.md)

これらの invariant が誤検知したり、取りこぼしたりしている場合も、上記の報告経路で連絡してください。

## 報告に含めると助かる情報

- 影響範囲（アプリ、プロトコル実装、計測ページ、CI）
- 再現手順
- 関連する invariant ID または該当ファイル名
- 提案する修正方針があれば
