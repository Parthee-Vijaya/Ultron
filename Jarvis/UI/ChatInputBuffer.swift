import Foundation
import Observation

/// Shared observable buffer between `ChatCommandBar` and `AppDelegate`. Lets
/// the app delegate push dictation transcripts into the chat's input field
/// without needing a direct reference to the SwiftUI view. ChatView owns one
/// instance and binds the TextField to `text`; when `AppDelegate` finishes
/// transcribing a chat-dictation clip, it writes the result to `text` and the
/// UI updates automatically.
@MainActor
@Observable
final class ChatInputBuffer {
    /// Current content of the command-bar text field.
    var text: String = ""
    /// True while AppDelegate is actively recording for chat-dictation. Used
    /// by the command bar to flip the mic button between record/stop visuals.
    var isRecording: Bool = false
    /// True while transcription is running after stop. Keeps the mic button
    /// in a "processing" state so the user sees something is happening.
    var isTranscribing: Bool = false
}
