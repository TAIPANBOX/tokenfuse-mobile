import LocalAuthentication

/// Face ID / passcode gate in front of destructive, signed actions (phone),
/// plus the watch's own wrist-detection gate for the kill ceremony there
/// (`confirmWristDetection`, below). On a bare simulator with no biometry or
/// passcode enrolled, `confirm` allows through: the slide-to-arm gesture was
/// already the deliberate confirmation, and a real device always has a
/// passcode, so this evaluates there.
enum Biometrics {
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy
        #if os(iOS)
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            policy = .deviceOwnerAuthentication
        } else {
            return true
        }
        #else
        // watchOS has no Face ID / Touch ID for a third-party app to evaluate
        // against (`.deviceOwnerAuthenticationWithBiometrics` is unavailable
        // there), so the floor here is the plain passcode policy. The kill
        // ceremony's own, stronger check lives in `confirmWristDetection`
        // below; this general gate is not called from watch code today, but
        // stays cross-platform so the file compiles once for both targets.
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            policy = .deviceOwnerAuthentication
        } else {
            return true
        }
        #endif
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    #if os(watchOS)
    /// The wrist kill ceremony's second act: confirms the watch has not left
    /// the owner's wrist since it was last unlocked with the passcode
    /// (`LAPolicy.deviceOwnerAuthenticationWithWristDetection`, watchOS 9+).
    /// Apple's own doc comment on the policy: "the authentication will also
    /// succeed if the wrist detection is enabled, correct passcode was
    /// entered in the past and the watch has been on the wrist ever since."
    ///
    /// This is deliberately NOT Apple Pay's double-click-side-button gesture;
    /// that mechanism is not exposed to third-party watchOS apps at all. What
    /// this actually checks is narrower and more honest: continuous wrist
    /// contact since the last passcode unlock, which is the platform's real
    /// "this is still the owner" signal on a device with no Face ID or
    /// Touch ID hardware to ask instead.
    ///
    /// `reason` is threaded through for API correctness (`evaluatePolicy`
    /// requires a non-empty `localizedReason` or it throws), even though
    /// Apple's own header notes the string is ignored for display on
    /// watchOS; the system supplies its own confirmation UI there.
    ///
    /// Mirrors `confirm(reason:)`'s simulator fallback exactly: with nothing
    /// enrolled (no passcode set, the common bare-simulator case),
    /// `canEvaluatePolicy` fails and this returns `true` with no prompt shown
    /// at all, rather than faking one.
    static func confirmWristDetection(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithWristDetection, error: &error) else {
            return true
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithWristDetection, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
    #endif
}
