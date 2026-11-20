import AppKit
import SwiftUI

/// How long a wrong-source run must get before it is converted without Tab.
enum AutoConvert: Int, CaseIterable {
    case off, gentle, normal, eager

    static let defaultValue = AutoConvert.normal

    /// Keys typed in the run (spaces excluded) before converting on its own.
    var threshold: Int? {
        switch self {
        case .off: return nil
        case .gentle: return 24
        case .normal: return 16
        case .eager: return 10
        }
    }

    var title: String {
        switch self {
        case .off: return "끄기"
        case .gentle: return "약하게"
        case .normal: return "보통"
        case .eager: return "강하게"
        }
    }

}

/// SpaType's preferences (UserDefaults). Every key here is covered by the Settings reset button.
enum Prefs {
    static let autoConvertKey = "autoConvert"
    /// Enter, while a suggestion is showing, converts and then still types Enter.
    static let enterAcceptsKey = "enterAccepts"
    /// Ask the on-device Apple model when the engine finds nothing in a paused line.
    static let aiJudgeKey = "aiJudge"
    static let all = [autoConvertKey, enterAcceptsKey, aiJudgeKey]

    static var autoConvert: AutoConvert {
        AutoConvert(rawValue: UserDefaults.standard.integer(forKey: autoConvertKey)) ?? AutoConvert.defaultValue
    }
    static var enterAccepts: Bool { UserDefaults.standard.bool(forKey: enterAcceptsKey) }
    static var aiJudge: Bool { UserDefaults.standard.bool(forKey: aiJudgeKey) && AIJudge.isAvailable }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoConvertKey: AutoConvert.defaultValue.rawValue, enterAcceptsKey: true, aiJudgeKey: true,
        ])
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.autoConvertKey) private var level = AutoConvert.defaultValue.rawValue
    @AppStorage(Prefs.enterAcceptsKey) private var enterAccepts = true
    @AppStorage(Prefs.aiJudgeKey) private var aiJudge = true

    private var caption: String {
        guard let keys = AutoConvert(rawValue: level)?.threshold else {
            return "자동으로 바꾸지 않아요. 제안이 뜨면 Tab이나 Shift 두 번으로 바꿔요."
        }
        return "다른 입력 소스로 잘못 친 글이 \(keys)타 이상 이어지면 Tab 없이 바로 바꿔요."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("자동 변환").font(.headline)
            Picker("", selection: $level) {
                ForEach(AutoConvert.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Enter로도 바꾸기", isOn: $enterAccepts).font(.headline)
            Text("제안이 떠 있을 때 Enter를 누르면 바꾼 뒤 Enter를 입력해요. 채팅은 고쳐진 문장이 전송돼요.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("AI 문맥 판정 (Apple Intelligence)", isOn: $aiJudge)
                .font(.headline)
                .disabled(!AIJudge.isAvailable)
            Text(AIJudge.isAvailable
                 ? "감지가 안 된 문장을 잠깐 멈췄을 때 기기 안의 Apple 모델로 한 번 더 확인해요. 내용은 기기 밖으로 나가지 않아요."
                 : "이 Mac에선 쓸 수 없어요: \(AIJudge.unavailableReason)")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("기본값으로 초기화") {
                    // Every SpaType preference; registered defaults take over again.
                    Prefs.all.forEach(UserDefaults.standard.removeObject(forKey:))
                    level = AutoConvert.defaultValue.rawValue
                    enterAccepts = true
                    aiJudge = true
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "SpaType 설정"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
