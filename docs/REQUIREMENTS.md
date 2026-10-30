# MultiKVM 要件

所有者（bull / susumutomita）が述べた要件です。実現方法、プロトコル、計測結果は [DESIGN.md](./DESIGN.md) に置きます。

## 背景

- 操作したいのは、自宅に置いた会社管理の Windows PC（DENSO）である。社内のレガシーシステムには、会社管理 PC からしか入れない。
- EDR があり、その PC には何もインストールできない。会社公式の Remote View はある。ここでは使わない。会社 PC での利用には IT 確認が必要である。
- 既存の IP-KVM（JetKVM）は、社内 LAN では速い。宅外からだと遅く、操作が辛い。

## 必須要件

- 操作される側の PC にソフトを入れない。取り込みは HDMI 入力と USB HID のハードウェア KVM である。
- KVM の箱は自宅ルータにつなぐ。会社ネットワークには接続しない。
- 宅外から iPhone（iPhone Duo）のネイティブアプリで、Tailscale 経由で操作する。実機でのビルドと接続は [#2](https://github.com/susumutomita/multikvm/issues/2)、宅外の直結経路は [#3](https://github.com/susumutomita/multikvm/issues/3) で確認する。
- 入力は、iPhone に Bluetooth 接続した HHKB Hybrid とトラックパッドである。
- iPhone を外部モニタにつないで表示できる。キーボード、トラックパッド、外部モニタの確認は [#4](https://github.com/susumutomita/multikvm/issues/4) で行う。
- 超低遅延である。目標はガラス to ガラスで約 50 ms である。内訳の測定は [#5](https://github.com/susumutomita/multikvm/issues/5) で行う。
- 余計な機能は作らない。所有者の言葉は「余計な機能は作らずに私のユースケースにはめて超高速にしたい」である。クリップボード共有、ファイル転送、録画は持たない。
- 公開リポジトリ（MIT）で開発する。

## 将来要件

今はやらない要件です。追跡は [#6](https://github.com/susumutomita/multikvm/issues/6) です。

- 2 台の PC を簡単に切り替える。1 台は会社 PC で、もう 1 台は私物でなくてよい。
- PC の通知が来たことを iPhone に知らせる。画面内容は含めない。

## 対象外

- 操作する側としての Windows と Mac。
- PC へのエージェント導入。
- クラウド中継。
