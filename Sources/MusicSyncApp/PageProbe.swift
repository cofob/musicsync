/// Development only: loading placeholders and load failures on screen now, so `check:flaky` can tell a page that
/// still loads or shows a message from one that is done.
@MainActor enum PageProbe {
    static var placeholders = 0
    static var failures = 0
}
