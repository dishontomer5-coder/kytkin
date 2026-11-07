// P3-10: The live watcher: the real AX thread, `AXElementTree`, `FrontmostObserver` and a run-loop timer. Kept out
// of the test target (project.yml), like KeyWatcher+Live, so no test can create an AXObserver or read a real app.
// AppController builds it in P3-14 once the bundled Public Suffix List has loaded (without it, SitePolicy never
// asks for an attach, D11).

import ApplicationServices
import Foundation

extension BrowserWatcher {
    static func live(extractor: DomainExtractor) -> BrowserWatcher {
        let siteReader = SiteReader(extractor: extractor)
        return BrowserWatcher(
            makeThread: {
                let thread = AXThread()
                thread.start()   // no wait: blocks sent before its run loop exists are queued (B16)
                return thread
            },
            makeEngine: { deliver in
                let clock = SystemClock()
                return BrowserWatchEngine<AXElementTree, FrontmostObserver>(
                    clock: clock, siteReader: siteReader,
                    makeTree: { AXElementTree(pid: $0) },
                    makeObserver: { FrontmostObserver() },
                    timer: RunLoopDeadlineTimer(clock: clock),
                    deliver: deliver)
            })
    }
}
