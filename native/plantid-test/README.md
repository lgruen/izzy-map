# Plant-ID native test (Core ML)

Question: can an iPhone 16e run the BioCLIP 2.5 image encoder (632M
parameters, fp16 weights, 1.26 GB) as a native app? The Safari/WebGPU test
(`probe/plantid/`) was killed by iOS on the 16e while preparing the model on
the GPU (2026-11-02).

The app loads the model three ways, one after another: Core ML's automatic
choice (`.all`, what a real app would use), Neural Engine only, GPU only.
For each it records:
- load time;
- first-run and median speed;
- the app's memory as iOS counts it (`phys_footprint`) and how much more iOS
  would allow (`os_proc_available_memory`);
- cosine and top-1 against the laptop's PyTorch fp32 embeddings for the same
  3 CC0 photos as the Safari test.

A UserDefaults step marker survives an iOS memory kill. The next launch
reports where the app died and skips that compute-unit choice. Copy results
puts everything on the clipboard.

## Build

```bash
# 1. the model + test data (gitignored cache; needs export_onnx.py's output first)
uv run --python 3.12 --with 'torch==2.7.*' --with 'torchvision==0.22.*' \
    --with open_clip_torch --with coremltools --with 'numpy<2.3' \
    python3 -I pipeline/plantid/export_coreml.py --model bioclip25    # ~50 s
# 2. the Xcode project (brew install xcodegen)
cd native/plantid-test && xcodegen generate
# 3a. Mac check (Mac Catalyst, ad-hoc signed; no Apple account needed)
xcodebuild -project PlantIDTest.xcodeproj -scheme PlantIDTest \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build
build/Build/Products/Debug-maccatalyst/PlantIDTest.app/Contents/MacOS/PlantIDTest -autorun -exit
# 3b. iPhone (Release build, installed with devicectl, then opened from the
#     Home Screen: Xcode's Run button adds the debugger and Metal validation,
#     which skew GPU memory and timings)
xcodebuild -project PlantIDTest.xcodeproj -scheme PlantIDTest -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=<team id> build
xcrun devicectl list devices
xcrun devicectl device install app --device <id> build/Build/Products/Release-iphoneos/PlantIDTest.app
```

TestFlight (the route used 2026-11-02; app record "IzzyMap Plant ID Test",
team T4HS4UL2LT, Apple ID signed in under Xcode → Settings → Accounts):

```bash
TEAM=T4HS4UL2LT native/plantid-test/testflight.sh   # archive + upload, ~5 min
```

If export fails with "Copy failed" and `rsync error: syntax or usage error`
in the `.xcdistributionlogs`, Homebrew's rsync 3.x shadowed Apple's openrsync
in PATH. The script puts /usr/bin first. A real native app would build and
upload from CI instead (decision 2026-11-02).

Before the first cable install:
- **Xcode's device components must be current.** On 2026-11-02 Xcode 27.2 logged
  "CoreSimulator is out of date", and the CoreDevice plug-in failed to load. That
  is why `simctl` and `devicectl` hung. Fix it by opening Xcode once and
  accepting the component install, or with `sudo xcodebuild -runFirstLaunch`.
- **The developer account must be signed in** under Xcode → Settings → Accounts.
- **The phone must be ready:**
  - connected by cable, unlocked, and set to trust the Mac;
  - Developer Mode on (Settings → Privacy & Security → Developer Mode, then
    restart). `-allowProvisioningUpdates` registers the phone in the account.

The iPhone build carries `com.apple.developer.kernel.increased-memory-limit`, as
a real app would. If signing refuses it, drop `CODE_SIGN_ENTITLEMENTS` from
project.yml and say so with the results. "at launch … iOS allows N MB more"
in the report shows the limit that applied either way.

How a test run behaves:
- **The three choices run in order:** automatic, Neural Engine only, GPU only.
- **Memory:** each step's peak footprint and lowest allowance come from a
  sampler running every 25 ms. They are written to the step marker every
  0.5 s.
- **After a kill:**
  - A kill during load, run or naming is blamed on that compute choice, which
    the next Start skips.
  - A kill during the same-session reload or "own photo" isn't blamed on
    anything.
  - A kill while the app is off-screen is reported as such.
- **Each choice starts once the previous model has been freed.** The app waits
  for this; on the Mac a freed model lingered briefly.

## Results

- **M4 Mac (Catalyst), 2026-11-02:** works with all three choices. Same
  answers as the laptop (cosine ≥ 0.9997), 0.09 s per photo with the Neural
  Engine, 0.14 s GPU only. The first-ever load (Core ML compiles for the
  Neural Engine) took 8.4 s; it took 0.06 s on the next launch (Core ML caches
  the compiled model on disk). App memory with the model loaded: 1.33 GB
  (Neural Engine), ~0.1 GB GPU only (on the Mac, Metal memory isn't counted in
  the app's footprint; on an iPhone it may be). A simulated kill mid-load
  (kill -9) was reported on relaunch, and that choice was skipped.
