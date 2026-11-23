# Pins — design (2026-11-23)

Saved points on the map with a colour, a note and photos, grouped into
projects, synced through the user's own iCloud, and exportable as a Google
Doc. This is the first feature in which the app UPLOADS anything, so what
leaves the device is part of the design (§2).

Decisions taken with Leo (2026-11-23): pins are private to one Apple ID (her
iPhone + the iPad, both on her Apple ID; Leo's phone keeps its own);
CloudKit, no backend of our own; pins are grouped by **project** (work
sites); the export is a native Google Doc in her personal Google Drive,
written as her own working notes, with a file through the share sheet as
the fallback. **This is a personal app: use the simple, supported route and
do not harden it against far-fetched scenarios** — Leo set aside a first
draft that owned its sync (CKSyncEngine over our own store, three-way
merges, tombstones) to guard against iCloud being signed out with changes
not yet uploaded.

Status of the facts this rests on: **[F]** an Apple engineer on the
developer forums (thread number), **[G]** Google documentation, **[U]**
unverified — proven by a spike before the milestone that depends on it.

## 1. What it is

- **Pin**: a point (WGS84), optional title, note (plain text), colour,
  photos, the project it belongs to (or none = "Unfiled"), when and how it
  was placed (GPS with its accuracy, or by hand on the map).
- **Project**: a name, a colour (the default for its pins; a pin may
  override it), an optional note, archived or not. One pin belongs to at most
  one project. No tags in v1; they can be added later.
- **Photo**: belongs to one pin; taken with the camera or chosen from the
  library; optional caption; an order within the pin.
- Word in the UI: "Pin". In code the types are `SavedPin`, `PinProject`,
  `PinPhoto` — "Pin" alone already means the search-result marker
  (`SearchModel.Pin`, `SearchPinView`).

Not in v1: tags; sharing with another Apple ID; a snapshot of what the maps
say at the pin (vegetation community, geology, soil unit); "save as pin"
from a search result or a plant identification; a map image in the export
(§6, licence question); GPX/KML.

## 2. What leaves the device, and where it goes

| Data | Goes to | Who can read it |
|---|---|---|
| Projects, pins, notes, photos | The PRIVATE CloudKit database of the Apple ID signed in on the device (container `iCloud.org.gruenschloss.izzymap`) | Only that Apple ID. A developer cannot read users' private databases. |
| An exported document | The user's own Google Drive, when she taps Export and has signed in to Google | Her Google account. The app asks for `drive.file` only: it can see and change files it created, nothing else in her Drive. |
| The same document as a file | Wherever she sends it from the share sheet | Her choice |

Nothing goes to a server of ours; non-negotiable 6 ("no web hosting of our
own") stands. No analytics. Records are ordinary CloudKit data: encrypted
in transit and at rest with keys Apple holds, not end-to-end (Leo: "doesn't
need to be super secure"). Synced photos keep their EXIF, including the
position; photos inside an exported document have it stripped (the document
may be passed on; the coordinates are in its text). Map data never enters a
pin record or an export, so `docs/LICENSING.md` is untouched — the one
place where it could (a map image in the export) is left out of v1.

## 3. Storage and sync: SwiftData with CloudKit

The supported native way for exactly this job: SwiftData models in a store
that the system mirrors to the private CloudKit database. The app writes no
sync code.

- **Models** (app target, `Sources/Pins/`; CloudKit's rules: every property
  optional or defaulted, no unique constraints, every relationship optional
  with an inverse):
  - `PinProject`: `id` (UUID), `name`, `colour` (palette NAME), `note`,
    `createdAt`, `modifiedAt`, `archivedAt?`, `deletedAt?`, `pins`
  - `SavedPin`: `id`, `project?`, `lat`, `lon`, `title`, `note`, `colour?`
    (override), `createdAt`, `modifiedAt`, `deletedAt?`, `placedBy`
    ("gps" | "map"), `accuracy?`, `altitude?`, `photos`
  - `PinPhoto`: `id`, `pin?`, `thumbnail` (small JPEG, stored inline — lists
    and the photo strip never load an original), `caption`, `sort`,
    `createdAt`, `width`, `height`, `bytes`, `original?`
  - `PinPhotoOriginal`: `photo?`, `data` (`.externalStorage`) — a model of
    its own so the full image is only read when a photo is opened or
    exported (external-storage attributes have been reported loading with
    their owner).
  - Enums are stored as strings. Once deployed to production, a CloudKit
    schema only grows **[F 771966]**: never rename or remove a property.
- **Photos**: camera captures become HEIC, long edge at most 4032 px (12 MP,
  about 1.5–2.5 MB), with capture date and position in EXIF; library picks
  keep their original bytes when HEIC/JPEG. Every device holds every photo
  (the store is mirrored whole) — which is also what "fully offline" wants.
  Cost: device storage and her iCloud quota (1,000 photos ≈ 2 GB; the free
  tier is 5 GB in total). The Storage screen shows the size on the device.
- **Deleting is soft**: Delete sets `deletedAt`; the pin leaves the map and
  sits in "Recently deleted" for 30 days, restorable; after that (or with
  "Delete now") it is deleted for real, with its photos. Deleting a project
  takes its pins along. This is the one safety net we add ourselves — it
  guards against the likely accident, a mistaken tap.
- **What the built-in sync does and does not do — accepted as is**:
  - Signing out of iCloud, or switching iCloud off for the app, removes the
    local store including changes that had not uploaded; signing in again
    brings back what was in iCloud **[F 811294]**.
  - When it syncs is the system's decision (usually seconds, occasionally
    much later); there is no "sync now".
  - A conflict (the same pin edited on both devices before they synced) is
    settled by the system, in effect the later change wins.
  - The app cannot count "3 photos waiting". The Pins screen states what it
    does know, as facts: iCloud on or off for this device (`CKContainer`
    account status: "iCloud is off on this iPhone — pins stay here"), the
    time of the last finished import or export ("Last synced with iCloud ·
    2 min ago" — not a claim that every edit is up) or, before any, a
    neutral "iCloud sync is on", and the last error
    (`NSPersistentCloudKitContainer.eventChangedNotification`): "iCloud
    storage is full", "Not signed in to iCloud", "Waiting for a
    connection", "iCloud sync failed" (code in Diagnostics). Each finished
    import re-reads the lists. Simulator / sync off: "On this iPhone only".
  - Not signed in to iCloud at all: pins simply stay on the device.
- **Development vs production**: Xcode builds talk to the CloudKit
  Development environment, TestFlight builds always to Production, with
  separate data **[F 771966, 842909]**. DEBUG builds use their own store
  file so Leo's phone never mixes the two. Tests and the simulator run with
  CloudKit off (`cloudKitDatabase: .none`, in-memory for unit tests,
  `-pinsStore <path>` for UI tests).
- **Pins reach TestFlight together with sync.** Whether a store that
  started local-only uploads its existing rows when CloudKit is switched on
  later is unverified **[U]**, so no build with pins ships before the
  container exists and the schema is deployed (§7).

## 4. On the map

- Pins are **runtime layers** (an `MLNShapeSource` added after the style
  loads and re-added on every style load, the `SpotlightPresenter` pattern),
  not part of the style JSON: the style is compared as a string and any
  difference reloads it, which an edit to a pin must never do.
- Paint order: … trees → **pins** → selection highlight (the red ring stays
  last and marks the selected pin).
- Mark: a filled circle in the pin's colour with a white halo and a thin
  ink keyline ("printed matter", DESIGN §2), radius about 4 pt at z6 growing
  to 8 pt from z14; no clustering — colour is the data, and clusters would
  lose it. Title label below the mark from z14, Latin-1 only: user text is
  folded (curly quotes, dashes, ellipsis → ASCII); a title that still is not
  Latin-1 gets no label.
- Colours: a fixed palette of eight named colours stored by NAME (so the
  values can be tuned later), none of them the reserved hues (selection red
  #FF3B30, tree green, the location dot's blue). Final values are chosen in
  the design pass against topo, aerial and TASVEG fills, with screenshots.
- Layers sheet → "Also show": a Pins tile (on by default). Archived
  projects' pins are hidden.
- **Adding**:
  - *Long-press the map* (0.5 s): a pin at that spot, a light haptic, its
    card opens with the title field ready. Must coexist with MapLibre's own
    gestures (verified in milestone 1).
  - *Pin button* in the map-controls capsule: a pin at the current
    location, recording the GPS accuracy. With no fix (the Wi-Fi iPad): the
    existing honest notice plus "long-press the map to place a pin" — never
    a silent guess at the map centre.
  - A new pin joins the project used last; the card's project chip changes
    it in one tap.
- **Tapping a pin** has priority over trees and overlay fills and opens the
  pin card.

## 5. Interface

- **Pin card** (a new `SelectedFeature` case in the existing panel; compact
  at the fit detent so the map stays usable): colour dot + title (edited in
  place) · project chip · photo strip (square thumbnails, camera button
  first — visual first) · note (saved as she types; the sheet goes to the
  large detent while the keyboard is up) · facts: latitude/longitude and
  the MGA55 grid reference (tap to copy), date, "GPS ± 5 m" or "placed on
  the map" · actions: Move (drag, or "to my location"), Open in Maps,
  Delete.
- **Pins screen** (a new `Presentation`; opaque list surface like Storage):
  projects with colour swatch, pin and photo counts; Unfiled; Archived;
  Recently deleted; the iCloud status line. A project: its pins (thumbnail,
  title, date, first line of the note), Show on map (fits the camera to
  them), Edit (name, colour, archive, delete), Select → Export.
  Reached from the project chip on any pin card, a "Pins" row in the Layers
  sheet, and ⌘P on the iPad. (Whether the screen also deserves its own map
  button is decided with screenshots in the design pass.)
- Design rules that apply: chrome is ink, colour is data; no toggles
  (checkmark rows); swatches square and keylined; targets ≥ 44 pt; Escape
  pops one level; no swipe-only actions.

## 6. Export

- **One document format: .docx, written by the app itself** (IzzyKit:
  WordprocessingML parts + a stored, uncompressed zip with CRC-32, no
  library; JPEGs do not compress anyway). Drive converts Word files into
  native Google Docs **[G]**; the same file is the share-sheet fallback and
  opens in Pages and Word.
- Why not the Docs API or HTML: the Docs API can only insert images from a
  PUBLICLY reachable URL **[G]** — her photos would have to be exposed, even
  if briefly; HTML upload drops embedded images according to recent reports.
- Contents (working notes for herself): project name, date range, number of
  pins; then per pin a heading, date, coordinates (lat/lon + MGA55) as a
  link that opens the spot in a maps app, the note, the photos (JPEG, long
  edge 1600 px, two across, EXIF stripped) with captions. Scope: a whole
  project, or the pins selected in its list. User text is cleaned of
  characters XML 1.0 forbids (a pasted vertical tab would make Word and
  Drive reject the whole file).
- **No map image in v1.** A rendered map would embed LIST tiles; aerial and
  Tasmap are CC BY-NC-ND and the document is for work. That needs a reading
  of the licence texts per layer first (Leo's rule: the licence text
  governs).
- **To Google**: sign in once with `ASWebAuthenticationSession` + PKCE (iOS
  OAuth client, no secret, reversed-client-ID redirect; Google rejects
  embedded web views **[G]**), scope `drive.file` (non-sensitive, no
  verification needed **[G]**), refresh token in the Keychain (this device
  only). Resumable upload with the target type Google Docs, then open the
  returned link (the Docs app if installed, else Safari). Each export makes
  a NEW Doc.
- The OAuth client id is not a secret but stays out of the public repo: a
  CI secret and an untracked local xcconfig, like the signing values.
- Failures: sign-in cancelled or revoked → sign in again; offline, Drive
  full, conversion refused or file over 50 MB → say so and offer the file.
- **[U] — spike before building the Google half**: that images inside a
  .docx survive Drive's conversion with their sizes, and how headings and
  the two-across photo layout come out. If the spike fails, the file route
  stands alone until another route is proven.

## 7. One-time steps for Leo

CloudKit (before the first TestFlight build with pins):
1. Developer portal → Identifiers → `org.gruenschloss.izzymap`: enable
   iCloud (CloudKit) with a new container `iCloud.org.gruenschloss.izzymap`,
   and Push Notifications. (The `identifiers` lane may be able to switch the
   capabilities on; assigning the container is probably manual, as the App
   Group was.) Rerun the setup workflow; the next TestFlight run re-creates
   the provisioning profiles.
2. Run the Debug scheme from Xcode on his iPhone (signed in to iCloud),
   tap Diagnostics (long-press the Storage gauge) → "Create iCloud schema"
   (it only asks for the next launch), stop the app and run it again FROM
   XCODE. That launch writes the record types into the Development
   environment before the pin store opens (Apple's way: never while the
   live store mirrors) and blocks for a while, which only the debugger
   tolerates; Diagnostics then shows the result under "schema creation".
   Fallback: the launch argument `-pinsCreateSchema YES` does the same.
3. CloudKit Console → Deploy Schema Changes to Production. Repeat 2–3
   whenever a model gains a property.

Google (before the Google half of milestone 3): a Google Cloud project →
enable the Drive API → Google Auth Platform: branding, audience External,
scope `drive.file`, **publish to production** (in "Testing" sign-ins expire
after 7 days) → an iOS client with the bundle id → give Claude the client
id. No cost.

## 8. Milestones

0. Heading arrow on the location dot (independent).
1. **Pins**: models, map layer, long-press and the pin button, pin card,
   projects, Pins screen, soft delete, Layers tile, Storage row — built and
   tested with CloudKit off.
2. **Photos**: camera + library, thumbnails, the existing full-screen
   viewer. Then CloudKit on (entitlements, status line, Leo's steps in §7),
   tested with Leo's iPhone and a simulator signed in to his Apple ID
   (Development) → first TestFlight build with pins.
3. **Export**: .docx writer (pure IzzyKit — built alongside 1–2) + share
   sheet; then the Drive spike, Google sign-in and upload.

Each milestone: adversarial review rounds before commit; IzzyKit tests for
everything without UI (Latin-1 folding, docx/zip); app tests on an
in-memory store; UI tests through new launch arguments (`-pinsStore`, a
long-press injector next to `-debugTaps`).
