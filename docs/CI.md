# CI: tests and TestFlight

Three GitHub Actions workflows, all on GitHub's Xcode 27 preview runner
(`runs-on: xcode-27`, Xcode 27.2 selected the same way everywhere):

| Workflow | File | When | What |
|---|---|---|---|
| CI | `.github/workflows/ci.yml` | every push / PR touching `ios/**` | `swift test` (IzzyKit), `xcodebuild test` on a simulator. No secrets, no signing. |
| IzzyMap setup | `.github/workflows/setup.yml` | manual only | validate secrets → App IDs → certificates and profiles |
| TestFlight | `.github/workflows/testflight.yml` | manual; push to `main` touching the app with `[testflight]` in the head commit message; 2nd Sunday of each month | refresh profiles → archive → upload to TestFlight |

Neither of the signing workflows ever runs on a pull request or in a fork
(`if: github.repository == 'lgruen/izzy-map'`). Their jobs that touch Apple
or Match-Secrets share one job-level concurrency group (`izzymap-signing`),
so two of them never write to Match-Secrets at once. GitHub keeps at most
**one** waiting job per group: a newer one replaces a waiting one, which
then shows as cancelled. That is why setup is **one job** (three steps):
as three chained jobs, each re-entered the queue and could cancel a
waiting TestFlight build, or be cancelled by one, half-way through setup.
Only a third run started while two are already in the group (running +
waiting) still replaces the waiting one — re-run it.

It is the Trio "browser build" pattern: an App Store Connect API key, plus
fastlane **match** keeping the signing certificate and profiles encrypted in
the private repo `lgruen/Match-Secrets`. **That repo is shared with Trio**:
Trio's Apple Distribution certificate signs IzzyMap too, and IzzyMap only
adds its own App Store profiles next to Trio's.

## Files

- `ios/Gemfile`, `ios/Gemfile.lock` — fastlane 2.241.2 (the version GitHub
  preinstalls on the Xcode 27 image), every dependency pinned. These live in
  `ios/` (not the repo root, where Trio keeps them) because everything
  iOS-specific lives there. As a result, a fastlane change is an `ios/**`
  change and triggers a TestFlight build like any other app change.
- `ios/fastlane/Fastfile` — the four lanes (below). `Matchfile` (storage:
  the Match-Secrets git URL, `type appstore`, **read-only by default**),
  `Appfile` (defaults only; the API key picks the team).
- `.github/actions/fastlane-setup/action.yml` — shared steps: select Xcode
  27.2, install the pinned gems (cached on the `Gemfile.lock` hash),
  optionally XcodeGen, sync the clock. Secrets are never in its environment.
- `.github/actions/xcodegen/action.yml` — installs ONE exact XcodeGen
  release (2.46.0) from its GitHub release zip, checked against the
  SHA-256 GitHub records for the asset; used by ci.yml and (through
  fastlane-setup) TestFlight builds, so both generate the project with the
  same version, whatever Homebrew ships that day. To update, bump
  `version` and `sha256` together; the digest comes from
  `gh api repos/yonaskolb/XcodeGen/releases/tags/<version> --jq '.assets[] | {name, digest}'`
  (the `xcodegen.zip` asset).
- `ios/Config/Release.xcconfig` — the Release signing hook (see "Signing").
- `.github/actionlint.yaml` — teaches actionlint the `xcode-27` label.

## Secrets (already set on lgruen/izzy-map)

`TEAMID`, `FASTLANE_KEY_ID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY` (the whole
`.p8` text), `MATCH_PASSWORD` (decrypts Match-Secrets), `GH_PAT`
(fine-grained, Contents read/write on `lgruen/Match-Secrets`). They are the
same values as in the Trio fork. Each one reaches only the fastlane step
that needs it, never gem or brew installs. The build lane removes
`GH_PAT`, `MATCH_PASSWORD` and `FASTLANE_KEY` from its environment once
match has run, so xcodegen and xcodebuild never see them. The derived git
auth header is masked in the logs as well, because the repo and its Actions
logs are public.

## Steps for Leo

0. Commit and push these files to `main`. GitHub only offers "Run workflow"
   for workflows that are on the default branch. A plain push starts no
   TestFlight run (see "Push builds" below); add `[testflight]` to the
   commit message to upload a first build straight away. That run should
   go through: its certs step makes the app's profile, and the extension
   ID that doesn't exist yet only causes a warning.
1. **GitHub → lgruen/izzy-map → Actions → "IzzyMap setup" → Run workflow**
   (branch `main`) → **Run workflow**. One job runs three steps in order:
   1. *Validate secrets*: GH_PAT can see the private Match-Secrets repo; all
      six secrets are well-formed; the API key works; the App Store Connect
      app record exists; match can decrypt Match-Secrets and its certificate
      hasn't expired. In read-only mode match doesn't ask the portal, so a
      *revoked* certificate is caught by step 3.
   2. *Identifiers*: finds or creates `org.gruenschloss.izzymap` (App
      Groups + Increased Memory Limit) and `org.gruenschloss.izzymap.assets`
      (the Background Assets extension, App Groups). The log lists each App
      ID's capability types.
   3. *Certificates and profiles*: match makes "match AppStore <id>"
      profiles for both IDs and commits them to Match-Secrets. It uses the
      existing (Trio's) certificate and never makes a second one.
2. Read the run's annotations. If one says a profile lacks
   `group.org.gruenschloss.izzymap`, assign the group by hand (see
   "App Groups" below), then run "IzzyMap setup" again.
3. **Actions → "TestFlight" → Run workflow** (branch `main`) → **Run
   workflow**. Expect very roughly 10–20 min of runner time (not measured yet). The build appears in
   App Store Connect → IzzyMap → TestFlight after Apple's processing
   (usually another 5–30 min). Apple emails you if processing rejects it.
4. Testers, once: App Store Connect → IzzyMap → TestFlight → *Internal
   Testing* → **+** → make a group, add testers, and tick **automatic
   distribution**. After that every upload reaches their phones without
   any further step. Internal testers must be users on the team: invite
   your partner under Users and Access with any role first. The
   alternative is an *external* group, which needs Beta App Review for the
   first build of every new version number.

### Push builds: only with `[testflight]`

A push to `main` uploads a build only when its **head commit message
contains `[testflight]`** (the gate job's `if:`; in a multi-commit push
only the last message counts). Why: with automatic distribution every
upload is a "new build available" notification on the tester's phone, and
one per commit is noise — ship when there is something to try. Even then,
changes that only touch tests (`IzzyMapTests`, `IzzyMapUITests`,
`IzzyKit/Tests`) or Markdown don't build (the `paths` filter). Manual runs
and the monthly keep-alive are unaffected. A push build doesn't
wait for CI's tests (as specified). With automatic distribution, a build
whose tests fail still reaches the testers. If that ever bites, switch the
push trigger to `workflow_run` on CI with `conclusion == 'success'`, and
check `event == 'push'` and the head repository, because `workflow_run`
runs with secrets. "What to Test"
gets the commit message and short hash.

## The lanes

Run them from `ios/` with `bundle exec fastlane <lane>`.

- **validate_secrets**: read-only. Checks secret formats (never prints
  values), the API key, the app record, App IDs (warns if missing), lists
  the team's distribution certificates with expiry dates, then runs match
  `readonly: true` with no app IDs. That run proves `GH_PAT` and
  `MATCH_PASSWORD` and checks the stored certificate's expiry date (not
  revocation: read-only match never asks the portal).
- **identifiers**: find-or-create both App IDs and their capabilities
  through the App Store Connect API (Spaceship `BundleId.find` / `.create`,
  `create_capability`). `APP_GROUPS` is Spaceship's
  `BundleIdCapability::Type::APP_GROUPS`. Increased Memory Limit has **no
  Spaceship constant and isn't in Apple's published CapabilityType enum**
  (App Store Connect OpenAPI 4.5.1). The lane uses the portal id
  `INCREASED_MEMORY_LIMIT` and treats any existing capability whose type
  contains `MEMORY` as present. If creating it fails (the API may neither
  list nor accept the type), you get a **warning**, not a failure. The
  authoritative check is in certs: the profile must carry
  `com.apple.developer.kernel.increased-memory-limit`.
- **certs**: match `readonly: false` for every registered App ID. It makes
  a profile that is missing, and deletes and re-makes one that Apple marked
  *Invalid*, which happens after any App ID capability change or a
  certificate revocation. It creates a **certificate** only when
  Match-Secrets holds none at all. Before match runs, the lane prints every
  distribution certificate's expiry, and it raises a warning annotation for
  any that expires within 30 days. After match, it warns if a profile lacks
  the App Group, and it **fails** if the app's profile lacks Increased
  Memory Limit (`IzzyMap.entitlements` requests it, so signing would fail
  anyway). TestFlight runs this lane before every build,
  so they repair themselves after a Trio certificate renewal.
- **build**: `xcodegen generate` → match `readonly: true` for the targets
  that exist in `project.yml` (`IzzyMap`, and `IzzyMapAssets` once it
  exists). It then writes `ios/Config/CI.generated.xcconfig` and runs gym:
  a Release archive with an `app-store` export and manual profiles. Last
  comes `upload_to_testflight` with `skip_waiting_for_build_processing`.
  Because a changelog is passed, pilot waits until the build appears in App
  Store Connect (at most 30 min), sets "What to Test", and returns.
  Processing continues on Apple's side. The changelog goes in as
  `localized_build_info` for the app's primary locale, because a plain
  `changelog` only patches localizations that already exist on the new
  build. Check the first upload's "What to Test" anyway (unverified). Build
  number = the highest of the most recent upload
  (`latest_testflight_build_number`, any version, processing builds
  included) and the last 200 uploads, + 1. The version stays
  `MARKETING_VERSION` from project.yml.

## Signing: why an xcconfig, not pbxproj patching

The Xcode project is generated, so Trio's `update_code_signing_settings`
(which patches the pbxproj) has nothing stable to patch. Instead:

- `project.yml` keeps `CODE_SIGN_STYLE: Automatic` (project level) for every
  local build, Debug or Release.
- The IzzyMap target's **Release** config uses `Config/Release.xcconfig`,
  which does `#include? "CI.generated.xcconfig"`. Locally that file doesn't
  exist, so nothing changes. In CI the build lane writes it: manual
  signing, `PROVISIONING_PROFILE_SPECIFIER = match AppStore
  $(PRODUCT_BUNDLE_IDENTIFIER)` (the lane asserts match used exactly that
  name), the distribution identity, and `CURRENT_PROJECT_VERSION`. A
  target-level xcconfig overrides project-level settings, but the Swift
  package targets (IzzyKit, MapLibre) never see it. Passing the same
  settings on the xcodebuild command line would hit the packages and fail
  ("does not support provisioning profiles").
- XcodeGen's iOS preset sets `CODE_SIGN_IDENTITY = iPhone Developer` *at
  target level*, which outranks any target xcconfig. So the target sets
  `CODE_SIGN_IDENTITY: "$(IZZY_CI_CODE_SIGN_IDENTITY:default=iPhone
  Developer)"`: the same value as before locally, and match's certificate
  name in CI.
- Verified with `xcodebuild -showBuildSettings` (2026-11-03). Without the
  CI file, Release shows Automatic / iPhone Developer / build 1. With it,
  Release shows Manual / the distribution identity / the match profile /
  the injected build number. In both cases Debug and the test targets are
  unchanged.

**Adding the IzzyMapAssets extension target:** use bundle id
`org.gruenschloss.izzymap.assets` and target name `IzzyMapAssets` (the
Fastfile's `SIGNED_TARGETS`). Give it the same two signing lines as
IzzyMap: `configFiles: {Release: Config/Release.xcconfig}` and the
`CODE_SIGN_IDENTITY` setting. Give app and extension the App Groups
entitlement `group.org.gruenschloss.izzymap`. The App ID and its profile
already exist after setup. Embedded extensions must carry the app's build
number; the shared xcconfig provides it.

## App Groups

The App Store Connect API can switch the App Groups *capability* on, but it
**can't assign a group** to an App ID. fastlane's `produce associate_group`
needs an Apple ID login, which this setup doesn't use. Do it once per App
ID: developer.apple.com → Certificates, Identifiers & Profiles →
Identifiers → `org.gruenschloss.izzymap.assets` (and check
`org.gruenschloss.izzymap`) → App Groups → Configure → tick
`group.org.gruenschloss.izzymap` → Save. Editing an App ID invalidates its
profiles. The next certs run (setup, or any TestFlight run) re-makes them.
The app's entitlements don't request the group yet. That starts when the
extension lands, and the certs lane's warning shows whether the profile
carries it.

## Certificate renewal (the Trio cert-nuke caveat)

An Apple Distribution certificate lasts one year, and Trio and IzzyMap share
one. **Trio owns its lifecycle.** Trio's "3. Create Certificates" runs
before every Trio build. If the certificate has expired and the repository
variable `ENABLE_NUKE_CERTS` is `true`, it runs `match nuke appstore`. That
**revokes every distribution certificate on the team and deletes every App
Store profile in Match-Secrets**, IzzyMap's included. Then it creates a new
certificate and Trio's profiles.

What that means for IzzyMap:

- Builds already installed keep working: revoking a certificate doesn't
  kill TestFlight installs.
- IzzyMap's next certs run re-makes its profiles against the new
  certificate. Every TestFlight run starts with one. The monthly keep-alive
  runs at 09:17 UTC on the same Sunday as Trio's 06:43 UTC run, so a
  renewal on Trio's side is picked up the same day. Or run "IzzyMap setup"
  by hand.
- IzzyMap has **no nuke lane, on purpose**. A nuke from here would revoke
  the certificate under Trio. If an IzzyMap run fails with "certificate …
  is not valid" or "not available on the Developer Portal", renew from
  Trio: lgruen/Trio → Actions → "3. Create Certificates", with
  `ENABLE_NUKE_CERTS = true` under Settings → Secrets and variables →
  Actions → Variables. Then re-run "IzzyMap setup".
- Never run `fastlane match nuke` by hand for this team without wanting
  both apps re-provisioned.

## Keep-alive

TestFlight builds expire after 90 days. The TestFlight workflow is
scheduled every Sunday at 09:17 UTC, and a tiny Ubuntu gate job lets only
the 2nd Sunday through (days 8–14, Trio's rule). On other Sundays the
build job shows as *skipped*. That build's "What to Test" starts with
"Monthly rebuild …". Every TestFlight run prints when the build it
uploaded expires (upload + 90 days) as a notice and on the run's summary
page, and logs the expiry of the newest build already on TestFlight
before it builds.

**The schedule switches itself off.** In a public repository GitHub
disables scheduled workflows after **60 days without repository activity**
(no pushes, issues, PRs …; GitHub emails the owner a few days before). A
disabled keep-alive means no monthly builds, so the installed build simply
expires about 90 days after the last upload and the app stops opening on
the testers' phones. Nothing in the repo can prevent this — a workflow
committing to the repo just to look busy is exactly what the rule is
meant to stop. The remedy is any one of:

- **push anything to `main`** (any commit counts as activity and re-arms
  the 60 days; with `[testflight]` in the message it also uploads a fresh
  build at once), or
- **GitHub → lgruen/izzy-map → Actions → TestFlight → "Enable workflow"**
  (shown on a disabled workflow's page), then **Run workflow** to upload a
  fresh build straight away if the last one is near its expiry date.

Rule of thumb: if the repo has been quiet for about two months, check the
Actions tab, and look at the expiry date of the newest run's summary.

## Troubleshooting

- **"Xcode 27.2 not found" / runner never starts:** the `xcode-27` label is
  a preview image. When it changes (Xcode 27 GA, a new label), update
  `runs-on` in all three workflows and `XCODE_CANDIDATES` in both `ci.yml`
  and `.github/actions/fastlane-setup/action.yml`.
- **"Couldn't decrypt the repo":** `MATCH_PASSWORD` is wrong. It must be
  Trio's.
- **GH_PAT cannot see Match-Secrets / git clone 403:** fine-grained tokens
  expire, after a year at most. Make a new one (repository access
  Match-Secrets, Contents read/write) and update `GH_PAT` in **both** Trio
  and izzy-map.
- **"required agreement" / "license agreement":** accept the updated
  Program License Agreement at developer.apple.com/account, wait a few
  minutes, re-run.
- **401 / NOT_AUTHORIZED from App Store Connect:** the API key was revoked,
  or the runner clock drifted (the setup action syncs it; re-run). The key
  is Trio's, created with "Admin" access as Trio's `fastlane/testflight.md`
  says; App ID and profile management needs it.
- **"No matching provisioning profiles found … readonly":** setup hasn't
  run, or a new target was added. Run "IzzyMap setup".
- **Profile doesn't include `com.apple.developer.kernel.increased-memory-limit`:**
  the App ID lost the capability. Run setup; if identifiers can't enable
  it, tick it in the portal and run setup again.
- **git push rejected while match commits:** Trio and IzzyMap wrote to
  Match-Secrets at the same moment. Re-run.
- **"The bundle version must be higher" / build number already used:** CI
  takes the highest of the last 200 uploads + 1, so an out-of-band upload
  (Xcode Organizer uses project.yml's build 1) shouldn't collide. If it
  does anyway, look at the upload list in App Store Connect.
- **Export fails with "Copy failed" (local runs):** Homebrew's rsync is
  first in PATH. The build lane shims `/usr/bin/rsync` in front
  automatically. The GitHub image has no Homebrew rsync.
- **Build logs:** a failed TestFlight run attaches `testflight-build-logs`
  (gym/xcodebuild logs only, 7 days). The repo is public, so the IPA and
  profiles are deliberately never uploaded as artifacts.

## Running lanes locally

Only for debugging. CI is the normal path, and `certs`/`build` write to
Match-Secrets / App Store Connect.

```sh
export PATH="/opt/homebrew/opt/ruby@3.4/bin:$PATH"   # brew install ruby@3.4 (system Ruby 2.6 is too old)
cd ios
BUNDLE_PATH=vendor/bundle bundle install            # vendor/bundle is gitignored
BUNDLE_PATH=vendor/bundle bundle exec fastlane lanes
```

Locally the lanes need the six secrets in the environment. `setup_ci` only
runs under `CI`, so a local match run uses the login keychain.
