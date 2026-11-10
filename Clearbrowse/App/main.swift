import UIKit

// Clearbrowse reads the Siri Remote in a UIApplication subclass (see BrowserApplication), which
// has to be named here; that's why the app has an explicit entry point instead of @main.
_ = UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    NSStringFromClass(BrowserApplication.self),
    NSStringFromClass(AppDelegate.self)
)
