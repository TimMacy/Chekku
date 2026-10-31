# チェック 〜 Chekku

An unofficial Mac app for [WeTrakr](https://wetrakr.com/) to mark episodes as watched. It displays the "Next episodes" section from the profile page, including respecting the set Spoiler Protection (Visible, Blurred, or Show Backdrop), remaining episodes, title block, episode number, and episode milestone if available. The app automatically refreshes when opened, an episode is marked as watched, or via the **Refresh** button.

<p align="center"><img width="100%" alt="チェック 〜 Chekku" src="https://github.com/user-attachments/assets/95468755-47f9-49da-aa6c-8753b68cac89" /></p>

## Connect to WeTrakr
1. Own API key required via [WeTrakr Settings → API](https://wetrakr.com/profile/settings/api).
2. Open Chekku, enter the **CLIENT ID**, and click **Connect**.
3. Click **Approve on WeTrakr** and complete the authorization in the browser.

Chekku uses device authorization with a client_id. No WeTrakr password or client_secret is entered in the app. Connection tokens are stored in macOS Keychain.

## Install

Requires macOS 15.2 or later. Download the app from [Releases](https://github.com/TimMacy/Chekku/releases), or build from source with `bash build.sh`.

If macOS blocks the app, choose [Open Anyway](https://support.apple.com/102445) under **System Settings → Privacy & Security**.

## License

MIT. See [LICENSE](LICENSE).

## Disclaimer
Chekku is an independent project and is not affiliated with or endorsed by WeTrakr.
