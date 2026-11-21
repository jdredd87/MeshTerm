# MeshTerm

A Delphi terminal for [Meshtastic](https://meshtastic.org) LoRa radios. It talks to the radio directly over USB serial or Bluetooth LE using Meshtastic's protobuf API (written by hand, with no extra libraries).

There are two front ends. They share the protocol, connection and crypto code.

| | Platforms | Connects over | Project |
|---|---|---|---|
| **MeshTerm** (VCL) | Windows | USB serial | `MeshTerm.dpr` |
| **MeshTermX** (FireMonkey, in progress) | Windows, Android | USB serial, Bluetooth LE (Android: USB OTG too) | `MeshTermX.dproj` |

## Features (VCL version)

- **Messages**: channel and direct messages, with delivery acks. Everything is logged to `messages.log`.
- **Nodes**: a sortable grid with search and filters (friends, local / internet, direct neighbours, last heard), friends, private notes, distance, battery and signal.
- **Map**: OpenStreetMap tiles with node markers. You can search for a place and set the radio's fixed location.
- **Channels**: create private channels with a random 256-bit key, share them as a QR code or link, and join from a link.
- **Internet**: an optional MQTT bridge (the radio's "proxy to client" mode) to the public Meshtastic server. It can also listen to extra topics and friends.
- **Alerts**: Windows notifications for direct messages, friends and private channels.

Settings are stored in `%APPDATA%\MeshTerm\MeshTerm.ini`. On Android they go in the app's home folder.

## Building

You need Delphi 13 (RAD Studio 37.0). The FireMonkey build also needs the Android SDK, which installs with Delphi.

```
build.bat                      MeshTerm.exe (VCL, Win64)
build-x.bat                    Win64\Debug\MeshTermX.exe
build-x.bat android            Android64 APK
build-x.bat android install    build and install with adb
```

## Hardware it was built with

A Seeed XIAO nRF52840 with a Wio-SX1262 LoRa board, running Meshtastic firmware 2.6. Any Meshtastic radio with USB serial or Bluetooth should work.

Over Bluetooth on Windows, pair the radio once in Windows Settings first (the default PIN is `123456`). Windows does not ask for the PIN on its own.
