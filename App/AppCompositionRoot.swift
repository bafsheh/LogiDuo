import LogiDuoFeatures

/// Builds the application's object graph.
///
/// This is the only place where concrete infrastructure is chosen and wired
/// into the presentation layer. Everything is created once, explicitly, and
/// handed down through initializers — there are no service locators.
@MainActor
final class AppCompositionRoot {
    /// Main-window navigation state, shared by the window and the menu bar.
    let router: AppRouter

    init(router: AppRouter = AppRouter()) {
        self.router = router
    }
}
