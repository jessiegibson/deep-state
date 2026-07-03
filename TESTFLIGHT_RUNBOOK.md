# TestFlight Runbook — macOS (com.soloai.deepState)

Run these on your Mac. The archive and upload steps need Xcode, your signing
certificates, and an App Store Connect API key or an interactive Xcode session.
They cannot run from the Cowork sandbox.

Scheme: `deep state Meeting Agent`
Project: `deep state Meeting Agent.xcodeproj`
Run all commands from the repo root (the folder containing the .xcodeproj).

## 0. Pre-flight (2 minutes)

    # Confirm you are on the right branch with the prep work
    git branch --show-current        # expect: refactor/structure
    git status -s                    # expect: the uncommitted prep edits

    # Confirm the build number bump landed
    grep CURRENT_PROJECT_VERSION "deep state Meeting Agent.xcodeproj/project.pbxproj"
    # expect: 20260625 on every line

Confirm in App Store Connect that the last uploaded build for version 1.1 has a
build number lower than 20260625. If you ever uploaded a date-style build today,
append a counter (for example 20260625.1) and re-run the grep edit.

## 1. Build and test locally (catches compile errors before archiving)

    xcodebuild \
      -project "deep state Meeting Agent.xcodeproj" \
      -scheme "deep state Meeting Agent" \
      -destination 'platform=macOS' \
      clean build

    # Optional but recommended: run the unit tests
    xcodebuild \
      -project "deep state Meeting Agent.xcodeproj" \
      -scheme "deep state Meeting Agent" \
      -destination 'platform=macOS' \
      test

If this fails, fix the errors before going further. Do not archive a broken tree.

## 2. Archive

    xcodebuild \
      -project "deep state Meeting Agent.xcodeproj" \
      -scheme "deep state Meeting Agent" \
      -configuration Release \
      -destination 'generic/platform=macOS' \
      -archivePath build/MeetingAgent.xcarchive \
      archive

## 3. Export and upload to App Store Connect / TestFlight

ExportOptions.plist is already in the repo (method app-store-connect, automatic
signing, team 472CR4BT3B). Upload needs authentication. Two options:

Option A — App Store Connect API key (no prompts, best for repeatability). Create a
key at App Store Connect > Users and Access > Integrations, then:

    xcodebuild -exportArchive \
      -archivePath build/MeetingAgent.xcarchive \
      -exportOptionsPlist ExportOptions.plist \
      -exportPath build/export \
      -authenticationKeyID <KEY_ID> \
      -authenticationKeyIssuerID <ISSUER_ID> \
      -authenticationKeyPath ~/private_keys/AuthKey_<KEY_ID>.p8

Option B — Xcode Organizer (interactive, simplest one-off). Open the project in
Xcode, Product > Archive, then in Organizer click Distribute App >
App Store Connect > Upload, and sign in when prompted.

Do not paste your Apple ID password or API key into this chat. Run these yourself.

## 4. After upload

- The build appears in App Store Connect > your app > TestFlight after processing
  (usually 5 to 30 minutes).
- Answer export compliance: the ITSAppUsesNonExemptEncryption=NO key should make
  this automatic. If still prompted, the app uses standard HTTPS only, which is exempt.
- Add the audioanalyticsd sandbox-exception explanation to the App Review / test
  notes so review does not flag the mach-lookup entitlement.
- Assign internal testers (no review needed) to test immediately. External testers
  require a Beta App Review pass first.

## 5. Commit the release state

Once a build is uploading or uploaded cleanly:

    git add -A
    git commit -m "release: macOS build 20260625 to TestFlight; export compliance + status docs"
    git push origin refactor/structure

Consider opening a PR to merge refactor/structure into main so main stops being
7 weeks stale.

## Realistic timing

If the archive builds clean on the first try and the App Store Connect record is
ready, you can have a build in internal TestFlight within roughly an hour. The most
common day-of blocker is a signing or provisioning mismatch surfacing only at
archive time. Budget for one round of fixing that.
