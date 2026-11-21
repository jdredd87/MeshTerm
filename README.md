# MeshTerm

A Delphi FireMonkey app for [Meshtastic](https://meshtastic.org) LoRa radios, for **Windows and Android**. It talks to the radio directly using Meshtastic's protobuf API (written by hand, with no extra libraries), over:

- **USB serial**: a COM port on Windows, or a USB OTG cable on Android
- **Bluetooth LE**: on both Windows and Android

## Features

- **Messages**: channel and direct messages, with delivery acks. Everything is logged to `messages.log`.
- **Nodes**:
  - search, filters (friends, local / internet, direct neighbours, has a location or note, last heard) and a choice of sort orders
  - friends, private notes, and a "no battery" flag
  - distance, battery and signal for each node, plus a details panel
- **Map**: OpenStreetMap tiles with node markers (pinch, drag and wheel zoom). You can search for a place and set the radio's fixed location.
- **Channels**: create private channels with a random 256-bit key, share them as a QR code or link, and join from a link.
- **Internet**: an optional MQTT bridge (the radio's "proxy to client" mode) to the public Meshtastic server. It can also listen to extra topics and friends.
- **Alerts**: system notifications for direct messages, friends and private channels.
- MeshTerm reconnects on its own after the radio reboots (for example after a settings change).

Settings are stored in `MeshTerm.ini`: `%APPDATA%\MeshTerm` on Windows, or the app's home folder on Android.

## Building

You need Delphi 13 (RAD Studio 37.0) with the Android SDK, which installs with Delphi.

```
build-x.bat                    Win64\Debug\MeshTermX.exe
build-x.bat android            Android64 APK
build-x.bat android install    build and install with adb
```

## Source layout

| Unit | What it does |
|---|---|
| `Meshtastic.Proto` | protobuf encoding and decoding |
| `Meshtastic.Client` | the radio session |
| `Meshtastic.Transport`, `.Port`, `.Usb.Android`, `.Ble` | serial / USB / Bluetooth links |
| `Meshtastic.Crypto`, `.Mqtt`, `.Bridge` | default-key AES, MQTT client, Internet bridge |
| `Meshtastic.Settings`, `.NodeView`, `.Places` | settings, node filtering and sorting, place search |
| `MapViewX` | the map control |
| `FmxSheet` | non-blocking dialogs |
| `MainFormX` | the UI |
| `QrCode` | the QR code encoder |

## Hardware it was built with

A Seeed XIAO nRF52840 with a Wio-SX1262 LoRa board, running Meshtastic firmware 2.6. Any Meshtastic radio with USB serial or Bluetooth should work.

Over Bluetooth on Windows, pair the radio once in Windows Settings first (the default PIN is `123456`). Windows does not ask for the PIN on its own.
