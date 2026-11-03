import UIKit

/// The idle timer is process-wide (`UIApplication.isIdleTimerDisabled`), but
/// following is per window. Each window reports whether it keeps the screen
/// on (following AND in the foreground); the screen stays on while at least
/// one does. One instance per process, owned by the App.
@MainActor
final class IdleTimerCoordinator {
    private var keepingAwake: Set<UUID> = []
    private var applied: Bool?
    private let apply: (Bool) -> Void

    init(apply: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.apply = apply
    }

    /// Whether a window should keep the screen on: following, and its scene
    /// in the foreground (active, or inactive under a banner or Control
    /// Center); a backgrounded or closed window never does.
    nonisolated static func keepsAwake(following: Bool, foreground: Bool) -> Bool {
        following && foreground
    }

    /// Records one window's state and updates the idle timer if the total changed.
    func update(window: UUID, keepsAwake: Bool) {
        if keepsAwake { keepingAwake.insert(window) } else { keepingAwake.remove(window) }
        let disabled = !keepingAwake.isEmpty
        guard disabled != applied else { return }
        applied = disabled
        apply(disabled)
    }

    /// The window went away.
    func remove(window: UUID) { update(window: window, keepsAwake: false) }

    var isIdleTimerDisabled: Bool { applied ?? false }
}
