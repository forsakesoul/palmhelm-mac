# Contributing

Thanks for looking at Palmhelm for Mac. Before you start, read the [README](README.md) for the requirements and the build steps.

## Development setup

```sh
scripts/bundle-bridge.sh                 # or --from-dist <palmhelm-bridge checkout>, see the README
xcodegen generate
xcodebuild build -project PalmhelmMac.xcodeproj -scheme PalmhelmMac \
  -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
scripts/test-mac.sh -derivedDataPath build/dd-test CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Please keep a change focused, add or update tests for behaviour you change, and run `scripts/test-mac.sh` before you open a pull request. Keep generated files and the Bridge binary out of commits (`.gitignore` covers them).

## Compatibility

The app talks to the Bridge and to `PalmhelmKit` over documented interfaces. A change that alters a request, response, or stored format must stay compatible with existing installs, or say clearly in the pull request what breaks and how users migrate.

## Licence of contributions

This project is licensed under the Apache License, Version 2.0. Under Section 5 of that licence, any contribution you intentionally submit for inclusion is licensed under the same terms, unless you state otherwise. You keep the copyright to your contribution.
