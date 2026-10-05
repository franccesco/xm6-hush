# xm6-hush

A small macOS daemon that stops your Sony WH-1000XM6 from being too loud when you let the outside world in.

When you switch the headphones to **Ambient Sound**, `xm6-hush` drops the system volume to a fixed level (20% by default) so you can hear the room without blasting your music over it. When you switch back to noise cancelling, or off, it restores the volume you had before.

The binary is called `xm6-volume`.

## How it works

The headset reports noise-control changes over Sony's proprietary MDR "v2" protocol, which runs on a Bluetooth Classic RFCOMM channel. The daemon:

1. Finds the paired headset and looks up Sony's vendor service UUID in its SDP records to get the RFCOMM channel (the channel number isn't fixed).
2. Performs the init handshake and ACKs every command the headset sends.
3. Decodes ambient-state reports (opcode `0x69`, subtype `0x19` on the XM6).
4. On a transition into Ambient Sound, saves the current volume and sets the target. On a transition out, restores the saved volume.

The first state report after connecting is not treated as a transition, so starting the daemon never changes your volume.

Everything lives in one file: `Sources/xm6-volume/main.swift`.

## Requirements

- macOS 13 or later
- Swift 6 toolchain (Xcode or Command Line Tools)
- A Sony WH-1000XM6, already paired and connected as an audio device

## Build

```sh
swift build -c release
```

Run this from the repository root. `Package.swift` embeds `Info.plist` through a relative path so the Bluetooth privacy check passes for a bare CLI binary. The output is under `.build/out/Products/Release/xm6-volume`.

## Usage

```sh
xm6-volume [--volume N] [--verbose]
```

| Flag | Meaning |
| --- | --- |
| `--volume N` | Volume (0-100) to use while Ambient Sound is on. Default 20. |
| `--verbose` | Print raw TX/RX frames and connection errors. |

macOS asks for Bluetooth permission the first time you run it.

## Run at login

Install the binary and ad-hoc sign it:

```sh
cp .build/out/Products/Release/xm6-volume ~/.local/bin/xm6-volume
codesign --force --sign - ~/.local/bin/xm6-volume
```

Then create a launch agent at `~/Library/LaunchAgents/com.local.xm6volume.plist` that runs `~/.local/bin/xm6-volume` with `RunAtLoad` and `KeepAlive`, logging to `~/Library/Logs/xm6-volume.log`, and load it:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.xm6volume.plist
```

To install a new build, stop the agent first, otherwise two processes compete for the headset:

```sh
launchctl bootout gui/$(id -u)/com.local.xm6volume
```

## Limitations

- **Only one client can hold the control channel.** While the daemon runs, the Sony app and other tools such as xm6-control can't connect. The daemon retries every 5 seconds if the connection fails.
- Unrecognised ambient report formats are dropped silently. If a firmware update changes the format, the symptom is that nothing happens. Run with `--verbose` to see the raw frames.
- Volume is read and set through `osascript`, so it acts on the system output volume, not a per-device level.

## Credits

The protocol comes from [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) and [Anneo22/xm6-control](https://github.com/Anneo22/xm6-control) (MIT).

This is an unofficial project and is not affiliated with Sony.
