# hangar

Install and update your own iOS apps on your phone, over your tailnet. One tap installs every new build.

hangar is two parts:

- **The server.** It holds the latest signed build of each app and serves it to iOS as an `itms-services` install. It also tells the phone how far each download has got.
- **The iOS app.** It lists your apps, shows which have a newer build, and installs one or all of them. It shows the progress the whole way, stays on screen until every download is done, then reopens the last app you tapped in its new build. hangar calls an app updated only once its new build has run.

```
app's build script ── hangar put app.ipa ──▶ server ──▶ hangar on the phone
                                               │            │ tap Update
                                               │◀───────────┘ iOS asks for the manifest, then the .ipa
                                               └── progress ──▶ ring fills, app reopens
```

## Publish a build

```sh
bin/hangar put path/to/App.ipa --notes 'Photos in Chats'
```

hangar reads the bundle id, name, build and icon from the `.ipa`. Nothing about an app is configured in hangar. `put` refuses a build that breaks any of these rules, and says why:

1. `CFBundleVersion` is a whole number that goes up with every build.
2. The app registers the URL scheme `<bundle id>-<CFBundleVersion>`, like `com.example.app-1017`.
3. The `.ipa` holds no macOS metadata (`._*` or `__MACOSX`), which sits outside the app's signature. Zip with `ditto -c -k --norsrc --noextattr --keepParent Payload App.ipa`.

Only that exact build answers that scheme. hangar opens it once iOS has installed the build, which tells hangar the install is done and launches the new build, using public API only.

## Update from inside an app

An app with its own update prompt can hand the update to hangar:

```swift
if await UIApplication.shared.open(URL(string: "hangar://update/com.example.app")!) {
    return
}
// hangar isn't installed: update the way you did before
```

hangar installs the latest build. iOS closes the old one, and hangar opens the new build when it's ready.

## Tell hangar which build runs

hangar only knows a build is installed once it has run. An app that tells hangar's server which build it runs, each time it comes to the front, shows as up to date even when you open it yourself:

```swift
// HangarURL is hangar's address, put in the app's Info.plist at build time
if let base = Bundle.main.object(forInfoDictionaryKey: "HangarURL") as? String, let url = URL(string: base + "/running"),
   let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": Bundle.main.bundleIdentifier ?? "", "build": build])
    URLSession.shared.dataTask(with: request).resume()
}
```

## Run the server

```sh
bun install
echo 'HANGAR_URL=https://<your host>/hangar' > config
bin/hangar serve      # 127.0.0.1:8792, or HANGAR_PORT
tailscale serve --bg --set-path=/hangar http://127.0.0.1:8792
```

Builds live in `~/.local/share/hangar` (or `HANGAR_DIR`). The log names each device and each step it takes, from the Install alert to the finished download.

| Route | |
| --- | --- |
| `GET /` | Install page for Safari |
| `GET /apps` | Each app's latest build, and the builds this phone last downloaded and last opened |
| `GET /events` | Server-sent `apps` and `install` (download progress) events for this phone |
| `GET /apps/<id>/<build>/manifest.plist` | The `itms-services` manifest |
| `POST /log` | What the app saw, written to the server log |
| `POST /running` | `{"id", "build"}`: the build an app runs on this phone |

## Build the app

`scripts/phone` builds `app/` with [xtool](https://github.com/xtool-org/xtool) and signs it on a Mac. Then it puts the build on hangar, so hangar updates itself. `scripts/shots <folder>` screenshots it on the iPhone Duo simulator with made-up apps.

## License

MIT
