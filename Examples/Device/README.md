# Device.app

The Workbench's Sync window (Sync > Show Device) on an iPhone or iPad: an
offline device kept in sync by ODataSync ([offline sync](../../docs/offline-sync.md)),
for trying it on a real device. It syncs over the network with a Workbench
on a Mac that serves its built-in service.

The device works the way the Sync window's does, and it is the same code:
`WorkbenchDevice` (the store, the sync engine, the conflict rules, the
request log) and `WorkbenchModel` (the built-in model), in
`Examples/Workbench`. This app adds UIKit screens, made in code, over them.

- **Data**: one entity at a time (the menu at the left shows which way each
  goes: Product and Stock both ways, Category, Supplier and Location down),
  with what that means above the rows. Pull down, or tap Sync, to sync;
  hold Sync for Download, Upload and Reconcile. For a both-ways entity,
  **+** makes an object, a swipe deletes one, and in a row's values a tap
  changes one.
- **Waiting**: changes not yet sent, with a badge on the tab. Swipe one that
  was set aside to retry it (the device's version over the service's) or
  discard it (the service's is read).
- **Conflicts**: conflicts met and how each was settled; tap one for its
  three versions (the one both last agreed on, the device's, the
  service's; `*` marks what changed).
- **Requests**: the device's own exchanges, newest first; tap one for what
  went and what came back.
- **Settings**: the Workbench's address, the conflict rule, Offline, Sync
  each change, Reset Device.

The device's data is kept between launches (Application Support), and the
app syncs when it opens or comes back to the foreground. A new address
means a new device, so its store is emptied.

## Running it

1. On the Mac, in the Workbench: **Sync > Serve on the Network**, or start
   it with `Workbench --serve [port]`. The built-in service is then served
   at `http://<the Mac's address>:8640/odata/` with **no authentication**,
   to anyone on the network. The status line shows the address. The data
   starts again from the seed rows.
2. Open `ODataKit.xcworkspace`, choose the **Device** scheme and an iPhone
   (or a simulator), and run. On a device, Xcode signs the app with your
   team: either choose it in the target's Signing & Capabilities pane, or
   put `DEVELOPMENT_TEAM = <your team ID>` in `Examples/Device/Local.xcconfig`,
   which git ignores. The simulator needs neither.
3. In the app's Settings, type the address. The first time, iOS asks to
   allow access to the local network: allow it.

Then try it as you would in the Sync window. For example: change a
product on the phone and in the Workbench (Change at the Service, or edit
it in the main window), sync, and see how the rule settles it. Or turn
Offline on, make changes, and turn it off again.

```sh
xcodebuild -workspace ODataKit.xcworkspace -scheme Device \
  -destination 'generic/platform=iOS Simulator' build
```

## What it is made of

| File | What |
|---|---|
| `main.m` | The app delegate: the tabs, a sync on opening |
| `DVSession.{h,m}` | The device for the address set, and the settings kept across launches |
| `DVControllers.{h,m}` | The screens |
| `Device.xcconfig` | iOS 15 and later, iPhone and iPad, the Info.plist keys (local network), signing |
| `Info.plist` | App Transport Security: plain HTTP on the local network |
| `../Workbench/WorkbenchDevice.{h,m}`, `WorkbenchModel.{h,m}`, `WorkbenchSupport.{h,m}` | Shared with the Workbench |

It links ODataKit, OTelKit, ODataIncrementalStore and ODataSync, built for
iOS from `ODataKit.xcodeproj` ([building](../../docs/building.md#ios)).
Syncing with other devices (ODataSyncPeerServer) is not part of the iOS
build; devices sync with a service.
