import Observation

/// Runs `body` now and again after any observable property it read changes, for as long as
/// `owner` lives. Lets AppKit objects follow `AppModel` the way SwiftUI views do.
@MainActor
func observeChanges<Owner: AnyObject>(owner: Owner, _ body: @escaping @MainActor (Owner) -> Void) {
    withObservationTracking {
        body(owner)
    } onChange: { [weak owner] in
        // onChange fires before the new value is stored; re-read on the next main-actor turn.
        Task { @MainActor in
            guard let owner else { return }
            observeChanges(owner: owner, body)
        }
    }
}
