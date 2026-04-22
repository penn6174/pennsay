import Foundation
import Combine

enum LoginStatus: String {
    case checking = "检查中..."
    case loggedIn = "已登录"
    case notLoggedIn = "未登录"
}

enum RecordingState {
    case idle
    case starting
    case recording
    case stopping
    case refining
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var loginStatus: LoginStatus = .checking
    @Published var recordingState: RecordingState = .idle
    @Published var currentText: String = ""
    @Published var lastNotification: String?
    @Published var availableUpdate: ReleaseInfo?

    var isRecording: Bool {
        switch recordingState {
        case .starting, .recording, .stopping, .refining:
            return true
        case .idle:
            return false
        }
    }

    var hasAvailableUpdate: Bool {
        availableUpdate != nil
    }

    var availableUpdateBadgeCount: Int {
        hasAvailableUpdate ? 1 : 0
    }

    func reset() {
        recordingState = .idle
        currentText = ""
        lastNotification = nil
        availableUpdate = nil
    }
}
