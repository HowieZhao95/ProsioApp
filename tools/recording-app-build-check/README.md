# Recording app build check

Run this after building the macOS app to confirm that every executable
architecture directly links `AVKit.framework`, the bundle metadata and Mach-O
UUIDs can be read, and the app passes strict code-signature verification.

```sh
python3 tools/recording-app-build-check/check.py /path/to/Prosio.app
```

To confirm that a candidate build has the same code-signing designated
requirement as the installed app:

```sh
python3 tools/recording-app-build-check/check.py /path/to/build/Prosio.app \
  --same-identity-as /Applications/Prosio.app
```

The command prints one compact JSON object. It exits nonzero and reports a JSON
error if a check fails. It only reads the bundles and invokes macOS inspection
tools (`lipo`, `dwarfdump`, `otool`, and `codesign`); it never launches the app.
The checks can be exercised on any platform with:

```sh
python3 -m unittest discover -s tools/recording-app-build-check -p 'test_*.py'
```
