import MultiKVMCore
import SwiftUI
import UIKit

@main
struct MultiKVMApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var session = SessionController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch session.phase {
            case .streaming, .negotiating:
                sessionScreen
            case .confirmingDevice(let version):
                confirmCard(version: version)
            default:
                connectForm
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(session.phase == .streaming)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            session.releaseKeys()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            session.disconnect()
        }
    }

    private var sessionScreen: some View {
        ZStack(alignment: .topLeading) {
            InputHost(session: session)
                .ignoresSafeArea()
            overlay
            if session.measurementFlash {
                Rectangle()
                    .fill(.white)
                    .frame(width: 64, height: 64)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .accessibilityLabel("F12 送信マーカー")
            }
            VStack {
                Spacer()
                controlBar
            }
        }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.statusLine)
            Text(String(format: "%.0f fps   %.0f kbps", session.overlay.fps, session.overlay.kbps))
            Text(rttText)
            Text(String(format: "表示投入 %.1f ms   破棄 %d", session.overlay.enqueueMs, session.overlay.dropped))
            Text("経路 \(session.overlay.path)")
            Text("時計 \(session.overlay.clockMs)")
            if session.capsLock {
                Text("Caps Lock")
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .accessibilityElement(children: .combine)
    }

    private var rttText: String {
        if let rtt = session.overlay.rttMs {
            return String(format: "RTT/2 %.0f ms", rtt / 2)
        }
        return "RTT/2 --"
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button("切断") { session.disconnect() }
            Button(session.pointerMode == .absolute ? "絶対" : "相対") {
                session.togglePointerMode()
            }
            Button("F12") { session.sendMeasureFlash() }
                .accessibilityLabel("測定用に F12 を送る")
        }
        .font(.system(size: 15, weight: .semibold))
        .buttonStyle(.borderedProminent)
        .tint(.white.opacity(0.16))
        .padding(.bottom, 12)
    }

    private func confirmCard(version: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("この JetKVM をペアリング")
                .font(.title2.weight(.semibold))
            Text(session.hostText)
                .font(.system(.body, design: .monospaced))
            Text("ファームウェア \(version.isEmpty ? "不明" : version)")
            Text("ペアリングすると、次回からこのアドレスだけを映像の接続先にします。パスワードは保存しません。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("接続しない") { session.rejectPairing() }
                Button("ペアリングして接続") { session.confirmPairing() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
    }

    private var connectForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MultiKVM")
                    .font(.largeTitle.weight(.semibold))
                Text("Tailscale 上の JetKVM に接続します。クリップボード、ファイル、録画はありません。")
                    .foregroundStyle(.secondary)
                TextField("http://100.x.y.z または MagicDNS", text: $session.hostText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("JetKVM のアドレス")
                if let warning = session.addressWarning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                }
                SecureField("ローカルパスワード（不要なら空）", text: $session.password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("ローカルパスワード")
                layoutPicker("キーボード", selection: $session.keyboardSide)
                layoutPicker("Windows の配列", selection: $session.hostLayout)
                Button("接続") { session.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isBusy)
                if case .closed(let reason) = session.phase {
                    Text(reason)
                        .foregroundStyle(.red)
                }
                Text(session.statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("外部モニタへは iPhone の画面ミラーで映ります。アプリは画面を録画しません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func layoutPicker(_ title: String, selection: Binding<KeyboardSide>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
            Picker(title, selection: selection) {
                Text("US").tag(KeyboardSide.us)
                Text("JIS").tag(KeyboardSide.jis)
            }
            .pickerStyle(.segmented)
        }
    }
}
