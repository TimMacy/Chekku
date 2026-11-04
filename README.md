# チェック 〜 Chekku

An unofficial Mac app for [WeTrakr](https://wetrakr.com/) to manually mark episodes as watched, or shows and movies automatically via [Infuse](https://firecore.com/infuse). The app displays the "Next episodes" section from the profile page, while respecting the set Spoiler Protection (Visible, Blurred, or Show Backdrop). It automatically refreshes on launch, after an episode is marked as watched, or via the **Refresh** button.

<p align="center"><img width="100%" alt="チェック 〜 Chekku" src="https://github.com/user-attachments/assets/792b3e5e-3b72-4cd9-b258-097640792c54" /></p>

## Connect to WeTrakr
1. A personal API key is required and can be obtained via [WeTrakr Settings → API](https://wetrakr.com/profile/settings/api).
2. Open Chekku, enter the **CLIENT ID**, and click **Connect**.
3. Click **Approve on WeTrakr** and complete the authorization in the browser.

Chekku uses device authorization with a client_id. No WeTrakr password or client_secret is entered in the app. Connection tokens are stored in macOS Keychain.

## Automatically mark playback as watched via Infuse
1. In Infuse 8.5.9 or later, enable **Settings → Playback → Now Playing API**.
2. Open Chekku on the same network and allow **Local Network** access when macOS asks.
3. While Chekku is open, it automatically marks episodes and movies as watched when playback reaches 90%, including when watching in the Infuse Apple TV app.

Chekku only reads Infuse's Now Playing status on the local network and talks to the WeTrakr API.

## Install

Requires macOS 15.2 or later. Download the app from [Releases](https://github.com/TimMacy/Chekku/releases), or build from source with `bash build.sh`.

If macOS blocks the app, choose [Open Anyway](https://support.apple.com/102445) under **System Settings → Privacy & Security**.

## License

MIT. See [LICENSE](LICENSE).

## Disclaimer
Chekku is an independent project and is not affiliated with or endorsed by either WeTrakr or Firecore/Infuse.
