# JTTY

A JTTY station for iPhone.

JTTY is the keyboard-to-keyboard digital mode introduced in WSJT-X 3.2 by
the WSJT development group: an asynchronous, RTTY-style mode with modern
weak-signal coding. Unlike FT8 there are no time slots. A transmission can
start whenever the operator presses send, lasts a few seconds, and carries
either contest-style exchanges in one or two compact frames or arbitrary
text at about 30 words per minute.

Plug the phone into a radio with a wired audio interface, tap Listen, and
the band appears as one transcript: every message heard on every frequency,
building frame by frame as it arrives. Many contacts run at once on a JTTY
band, so a tap on any message, or on the waterfall, opens the conversation
on that frequency alone, with its own quick messages and message field, and
New opens a fresh one for calling CQ. Contest mode, off by default, adds
the serial number, a queued next station and the contest exchanges.

## The mode

- 4-GFSK at 31.25 baud, tone spacing equal to the baud rate, BT 2.0.
  Occupied bandwidth about 127 Hz.
- A frame is 13 sync symbols followed by 46 data symbols: 59 symbols,
  1.888 seconds. A transmission is 1 to 16 frames.
- Each frame carries 34 bits: a 32-bit source word, a reserved bit and an
  end-of-message flag. A CRC-12 brings that to 46 bits, and a rate-1/2
  tail-biting convolutional code with constraint length 10 (generators 1167
  and 1545 octal) produces the 92 coded bits that become 46 Gray-coded
  tones.
- The source word is one of: six callsign actions (`CQ K1ABC CQ`, `K1ABC`,
  `TU K1ABC CQ`, `K1ABC TU`, `K1ABC AGN?`, `TU NOW K1ABC`) using the FT8
  family's 28-bit standard-callsign packing; a typed contest exchange
  (serial, zone, state, class and section, grid, and so on); one of
  eighteen control phrases such as `AGN?` and `NR?`; or five characters of
  text from a 64-character alphabet.

Free text is packed by a dynamic program that finds the fewest frames
reproducing the text exactly: `CQ K1ABC CQ` is one frame, `W9XYZ 599 107`
is two, and the sentence `THE QUICK BROWN FOX JUMPED OVER THE LAZY DOG.` is
nine.

## The receiver

Audio at 12 kHz becomes a complex analytic signal at 6 kHz. The sync
pattern is correlated against every 2 ms of the first quarter-frame of a
1.25-frame window, giving a surface over start time and frequency. Peaks
are picked band by band, refined to a few milliseconds and half a hertz,
checked against the 13 sync tones, and the 46 data symbols behind each
survivor are correlated against the four tones and handed to the decoder.

The decoder is a list wrap-around Viterbi over the 512-state trellis,
keeping the best four paths per state, run twice round. Branch metrics are
energies of coherent sums over blocks of 1, 2 or 4 symbols, tried in that
order, with a final attempt on half-symbol energies for signals whose phase
will not hold still. The top four closed paths go to the CRC; a decode must
then also pass the full source grammar before it is shown or used.

Every decoded frame is re-synthesised and subtracted from the window and the
search repeated, so a weaker signal under a stronger one is found on the
second pass. The three previous windows are re-swept with the signal taken
out, since their own candidates may have been sitting on it. Frames one
period apart on one frequency are joined into messages; a missed frame
leaves ` ... ` in the text.

Measured on the Mac over synthetic signals in white noise: 20 of 20 decodes
at −14 dB in 2500 Hz, 3 of 20 at −17 dB. The off-air sample that ships with
WSJT-X decodes completely: ten frames, `RAN ALL NIGHT ON BAND NOISE - NO
FALSE DECODES!`.

## Layout

- **`jttylib/`** — Swift package.
  - `Sources/CJTTY` — the modem in C: source codec and text packer
    (`codec.c`), CRC and tail-biting convolutional code with the list
    decoder (`tbcc.c`), GFSK synthesis (`modem.c`) and the receiver
    (`receiver.c`, on Accelerate for the FFTs).
  - `Sources/JTTYLib` — the Swift API: `JTTYEncoder` and `JTTYTransmission`
    for sending, `NativeMacro` for the quick messages, `JTTYReceiver` for
    streaming audio in, and `MessageAssembler` for turning frames into
    messages.
- **`app/`** — the iOS app (SwiftUI, iOS 17+, project generated with
  XcodeGen). `Audio/RadioAudioController` wires AVAudioEngine in
  `.measurement` mode so iOS does not apply gain control or noise
  suppression to the signals the decoder wants.
- **`tools/`** — `jttytest.c`, a command-line harness for the modem, and
  `make_app_icon.py`, which draws the icon.

## Building

```sh
cd jttylib && swift test

cd app && xcodegen generate
xcodebuild -project JTTY.xcodeproj -scheme JTTY \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

On a simulator, launching with `-demo` fills the screen with made-up traffic.

The command-line harness:

```sh
clang -O2 -I jttylib/Sources/CJTTY/include jttylib/Sources/CJTTY/src/*.c \
    tools/jttytest.c -framework Accelerate -o /tmp/jttytest
/tmp/jttytest vectors          # golden vectors from the specification
/tmp/jttytest pack             # text packing
/tmp/jttytest loop -14         # loopback at an SNR
/tmp/jttytest wav file.wav 1500 100
```

## Radio setup

1. Connect a wired audio interface between the phone and the radio's data
   port.
2. Set your callsign in Settings. Set the band and dial frequency so the log
   is right.
3. Tune the radio in USB and tap Listen. Tap the waterfall to put the
   transmit frequency on a signal, or on a clear spot. With "Choose a clear
   frequency" on, calling CQ moves to the quietest spot nearby by itself.
4. Set the transmit level so the radio shows little or no ALC movement.
5. Key the transmitter with VOX. There is no CAT or PTT control.

The first transmission after an hour's quiet asks which band the radio is
on, so the log stays right across a retune. The quick messages are WSJT-X's
F1 to F8 in the same order: `CQ %M CQ`, `%H %E`, `%H TU CQ %M CQ`, `%M`,
`%H`, `TU NOW %Q %E`, `%H AGN?`, `%E`, where `%H` is the station you are
working. Touch and hold a message in the transcript to call that station,
which also moves the transmit frequency onto them. Sending a TU message
logs the contact and moves the serial number on.

## Acknowledgements

JTTY is the work of Joe Taylor K1JT and the WSJT development group; the
protocol description, source-encoding specification and design notes that
ship with WSJT-X 3.2 are what this implementation was written from, and
WSJT-X's sample recording is the test fixture. This app is an independent
implementation and contains no WSJT-X code.
