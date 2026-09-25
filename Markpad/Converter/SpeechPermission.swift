import Foundation
import MarkpadCore
import Speech

/// Asks for speech-recognition permission on behalf of audio conversions.
///
/// Lives in the app rather than MarkpadCore on purpose: requesting permission crashes any
/// process whose Info.plist lacks `NSSpeechRecognitionUsageDescription` — the test runner and
/// the Quick Look extension among them — so only the app, which declares it, may ask.
enum SpeechPermission {
    /// Prompts once if the user has not yet decided. Returns whether transcription may run.
    ///
    /// On macOS 26 and later transcription uses `SpeechAnalyzer`, which needs no permission,
    /// so nothing is asked there.
    @MainActor
    static func request() async -> Bool {
        guard AudioImporter.requiresSpeechAuthorization() else { return true }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    /// Languages that can be transcribed on this Mac without sending audio anywhere.
    static func supportedLocaleIdentifiers() async -> [String] {
        await AudioImporter.supportedLocaleIdentifiers()
    }
}
