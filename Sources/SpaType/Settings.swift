import AppKit
import SwiftUI

/// How long a wrong-source run must get before it is converted without Tab.
enum AutoConvert: Int, CaseIterable {
    case off, gentle, normal, eager

    static let key = "autoConvert"
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

    static var current: AutoConvert {
        AutoConvert(rawValue: UserDefaults.standard.integer(forKey: key)) ?? defaultValue
    }

    // ponytail: the Enter setting lives here too; split into a Prefs type if a third setting appears.
    /// Enter, while a suggestion is showing, converts and then still types Enter.
    static let enterAcceptsKey = "enterAccepts"
    static var enterAccepts: Bool { UserDefaults.standard.bool(forKey: enterAcceptsKey) }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [key: defaultValue.rawValue, enterAcceptsKey: true])
    }
}

struct SettingsView: View {
    @AppStorage(AutoConvert.key) private var level = AutoConvert.defaultValue.rawValue
    @AppStorage(AutoConvert.enterAcceptsKey) private var enterAccepts = true

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
            HStack {
                Spacer()
                Button("기본값으로 초기화") {
                    // Every SpaType preference; registered defaults take over again.
                    UserDefaults.standard.removeObject(forKey: AutoConvert.key)
                    UserDefaults.standard.removeObject(forKey: AutoConvert.enterAcceptsKey)
                    level = AutoConvert.defaultValue.rawValue
                    enterAccepts = true
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
