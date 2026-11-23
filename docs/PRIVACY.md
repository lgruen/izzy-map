# IzzyMap — privacy

IzzyMap is a private, non-commercial offline map of Tasmania's vegetation,
geology and soils for a handful of personal devices. It is distributed
through TestFlight only. There are no accounts, no advertising and no
analytics, and the app has no server of its own.

## What stays on the device

- **Location** is used to show where you are on the map and to place a pin
  at your position. It is not sent anywhere.
- **Plant identification** runs on the device. Photos you identify are not
  uploaded.
- Map layers, search and the plant, tree and soil tables work offline from
  data stored on the device.

## What the app fetches

Map packs come from Apple's servers. Optional extras (field-guide chapters,
plant photos, tree data sheets, soil reports) and live map tiles are
downloaded straight from their publishers (Land Tasmania's LIST, NRE
Tasmania, the Understorey Network, the City of Hobart's ArcGIS pages). Those
servers see the request and the device's IP address, as any website does.
The app sends them nothing else.

## Pins (your own notes and photos)

Pins, their notes and photos are stored on the device and synced through
**your own iCloud account** (Apple CloudKit, the private database of the
Apple ID signed in on the device). Only that Apple ID can read them; the
developer cannot. Turning iCloud off for the app stops the sync.

## Export to Google Docs

Export only happens when you ask for it. If you choose "Google Docs", you
sign in to your Google account and the app requests one permission,
`https://www.googleapis.com/auth/drive.file`: it can create files in your
Google Drive and open or change the files it created itself. It cannot see
anything else in your Drive. The app uploads the document you exported
(the selected pins' titles, notes, coordinates and photos) to **your own
Drive** and nothing else. It reads no Google user data beyond what is
needed to complete that upload, stores the sign-in token only in the
device's Keychain, and shares nothing with anyone. You can remove the
app's access at any time at <https://myaccount.google.com/permissions>.

IzzyMap's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## Deleting your data

Delete pins in the app (they leave iCloud too), delete the app's iCloud
data under Settings → your name → iCloud → Manage Storage, and delete
exported documents in Google Drive. Removing the app removes everything it
stored on the device.

## Contact

Questions: open an issue at <https://github.com/lgruen/izzy-map/issues>.
