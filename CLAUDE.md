# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`xm6-volume` is a macOS daemon for a Sony WH-1000XM6. It listens for noise-control changes over Bluetooth and sets the system volume to a fixed level (default 20%) while Ambient Sound (transparency) is on, then restores the previous volume when the mode changes. Everything lives in one file, `Sources/xm6-volume/main.swift`. There are no tests and no linter.

## Commands

```
swift build                                        # debug build -> .build/out/Products/Debug/xm6-volume
swift build -c release                             # release build -> .build/out/Products/Release/xm6-volume
.build/out/Products/Debug/xm6-volume --verbose     # run; --verbose prints raw TX/RX frames; --volume N sets the level (0-100)
```

The build output is under `.build/out/Products/`, not the usual `.build/debug/`.

Installed copy and login agent (the agent runs the installed copy, not the build output):

```
cp .build/out/Products/Release/xm6-volume ~/.local/bin/xm6-volume && codesign --force --sign - ~/.local/bin/xm6-volume
launchctl bootout gui/$(id -u)/com.local.xm6volume
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.xm6volume.plist
```

The agent logs to `~/Library/Logs/xm6-volume.log`. It restarts automatically (`KeepAlive`), so to test a new build you must `bootout` it first or two processes will compete for the headset.

## Architecture

- **Transport:** Sony's proprietary MDR "v2" protocol over a Bluetooth Classic RFCOMM channel. The channel number is not fixed. `Session.start()` looks up the vendor service UUID (`956C7B26-…`, falling back to `96CC203E-…`) in the paired headset's SDP records and opens that channel. The headset must already be connected as an audio device.
- **Only one client can hold the control channel.** If the launchd agent is running, the Sony app, xm6-control, or a second copy of this binary cannot connect. A leftover channel just after another process exits can also make the first connect attempt fail silently (failures print only with `--verbose`). `connect()` retries every 5 seconds.
- **Framing (`Frame`):** `0x3E | type | seq | length(4, big-endian) | payload | checksum | 0x3C`, with `0x3E`, `0x3C` and `0x3D` escaped inside the frame. The checksum is a byte-wise sum of the unescaped body. `FrameParser` reassembles frames from fragmented reads.
- **Handshake and ACKs:** send `00 00` (init) first. Every command received from the headset must be ACKed with type `0x01` and the flipped sequence bit (`seq ^ 1`). The headset's own ACKs update our sequence counter. Skipping the ACK makes the headset stop responding.
- **Ambient state (`decodeAmbient`):** the XM6 reports noise-control changes as opcode `0x69` with subtype `0x19`, a 9-byte payload `[69, 19, 01, enable, ambientFlag, av, level, naFlag, naSens]`. The initial `0x66` query is answered in the older subtype `0x17` format. The decoder also accepts `0x15` and `0x22` from other firmware. Unrecognised subtypes are silently dropped, which looks like "nothing happens" when the headset changes dialect.
- **Volume logic (`Session.handle`):** acts only on transitions. Entering ambient saves the current volume (via `osascript`) and sets the target. Leaving ambient restores the saved value. The first state report after connecting is not a transition, so starting the daemon never changes the volume.
- **Bluetooth permission:** `Sources/xm6-volume/Info.plist` is embedded into the binary at link time (the `-sectcreate` flags in `Package.swift`) so the privacy check passes for a bare CLI. The relative path in `Package.swift` means `swift build` must run from the repo root.

## Reference

The protocol was taken from Gadgetbridge and [Anneo22/xm6-control](https://github.com/Anneo22/xm6-control) (MIT). When adding commands, that repo's `Sources/SonyHeadphonesKit/Protocol/Commands.swift` and `Opcodes.swift` document the byte layouts, including battery, EQ, speak-to-chat and multipoint. Test new payloads with `--verbose` before relying on them.
