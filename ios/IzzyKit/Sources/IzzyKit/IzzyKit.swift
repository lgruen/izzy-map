public enum IzzyKit { public static let version = 1 }

/// How IzzyKit writes numbers (one policy, applied everywhere):
///
/// - **Readouts meant to be copied** (the grid pill's MGA and lat/lon) are
///   locale-independent: POSIX digits, no grouping, "." decimal
///   (`GridReadout`), so they paste into LISTmap or a GPS unchanged.
/// - **Prose numbers** (geology ages, pre-1750 extents, counts in sentences)
///   use Foundation's `FormatStyle` with the user's current locale for
///   grouping and the decimal mark. The app's words are English only, but
///   figures follow the device's region format, as everywhere else on iOS.
///   Formatters take a `locale:` parameter (default `.current`) so tests pin
///   en_AU.
/// - Halves round away from zero on the number as written (2.25 → 2.3,
///   500.5 → 501), not with JavaScript's or printf's tie rules.
public enum ProseNumbers {}
