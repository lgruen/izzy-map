import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// The Background Assets downloader extension that Apple hosting requires
/// (docs/NATIVE_PLAN.md §2). The system runs it — also while the app isn't —
/// to download the packs by their manifest policies: `vector` before first
/// launch (essential), `topo` and `relief` during install (prefetch), and
/// background updates of any pack that is on the device.
///
/// Apple's "Apple-Hosted, Managed" template: `StoreDownloaderExtension`
/// supplies the whole implementation. `shouldDownload(_:)` is left at its
/// default (download everything the policies say); Apple's guidance is to
/// omit it unless packs need filtering at runtime. Never implement the
/// inherited `BADownloaderExtension` requirements here
/// (StoreKit/SKDownloaderExtension.h).
@main
struct IzzyMapAssetsExtension: StoreDownloaderExtension {}
