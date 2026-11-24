# IzzyMap — privacy

IzzyMap is a private, non-commercial offline map of Tasmania's vegetation,
geology and soils for a handful of personal devices. It is distributed
through TestFlight only. There are no accounts, no advertising and no
analytics, and the app has no server of its own.

## What stays on the device

- **Location** is used to show where you are on the map and to place a pin
  at your position. Apart from the position saved with a pin or a pin
  photo (see Pins below), it is not sent anywhere.
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
developer cannot. Turning iCloud off for the app stops the sync; without
iCloud the pins stay on that device only.

A pin holds its position (with the GPS accuracy and altitude when it was
placed at your location), its title, note, colour, project and photo
captions. Photos you take for a pin keep their capture date and, when a
position fix is known, that position in the photo's own data (EXIF);
photos added from your library keep the date and position they already
carry.

Exporting pins as a Word file ("Share file") hands the file to the system
share sheet; it goes wherever you send it. Photos in an exported document
carry no metadata (no position or date inside the image files).

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

Delete pins in the app: a deleted pin or project stays in "Recently
deleted" (on the device and in iCloud) for 30 days, then it is deleted for
good, from iCloud too; "Delete now" there does that at once. You can also
delete the app's iCloud data under Settings → your name → iCloud → Manage
Storage, and delete exported documents in Google Drive. Removing the app
removes what it stored on the device, except the Google sign-in token,
which iOS keeps in the Keychain: the app deletes it the first time it runs
after being installed again. "Sign out of Google" in the export sheet
deletes it at any time, and removing the app's access at the Google link
above makes it useless.

## Contact

Questions: open an issue at <https://github.com/lgruen/izzy-map/issues>.
