import SwiftUI

/// Branded wordmark rendered above the chat greeting. SF Pro Rounded Bold,
/// 20pt, 4pt tracking, plain white — no gradient, no accent bar, no pulse.
/// Kept simple per user preference; the rest of the empty-state (greeting +
/// rotating line) carries the personality, and the wordmark just grounds
/// the brand without competing for attention.
struct JarvisWordmark: View {
    var body: some View {
        Text("J.A.R.V.I.S")
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .kerning(4)
            .foregroundStyle(Color.white)
            // Soft black drop so the mark reads crisply on the dark navy
            // chat backdrop; otherwise the chunky rounded letters start
            // feeling a touch heavy.
            .shadow(color: Color.black.opacity(0.45), radius: 2, y: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("J.A.R.V.I.S")
    }
}
