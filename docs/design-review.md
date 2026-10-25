# Design review: JTTY for people who know messaging apps

October 2026. Reviewed the Band, Conversation, Log and Settings screens on
the iPhone and iPad, alongside iMessage and the Hops Meshtastic app
(`/Users/asm/d/Hops-App`, in particular `docs/PRODUCT_VISION.md`).

## The frame

A first-time JTTY user who knows iMessage arrives with a mental model:
a list of conversations with people, each with a name, a preview and a
time; a thread of bubbles; a compose bar; something that tells them a
message arrived. JTTY already has most of this shape. What it lacks is the
small set of signals that make a messaging app feel alive, and it leans on
radio vocabulary in a few places where the messaging word would do.

Hops' principles apply directly and are worth adopting as JTTY's:

- **Familiar.** Standard iOS navigation, gestures and components. Where
  the radio forces a departure from Messages, say so up front.
- **Simple.** Pro controls stay, but out of the first screen's way.
- **Reliable.** Every sent message ends in a truthful state, with retry.
- **Honest.** No label borrowed from iMessage may claim more than the radio
  can prove. Hops renamed "Delivered" for this reason; JTTY's "heard back"
  is already honest and should keep its meaning.

What JTTY must not lose: the waterfall, "Everything" mode, the transmit
and receive frequency controls, contest mode, quick messages, logging and
QRZ upload. None of the recommendations remove any of these.

## What a messaging user sees today

1. The tab is called **Operate** with an antenna icon. Nothing else in the
   app is called "operate".
2. Conversation rows have no **unread** state. A reply to your CQ that
   arrived while you were in Settings looks the same as everything else.
3. Timestamps are always `HH:mm`, with no sense of "yesterday".
4. A conversation is titled by its **frequency** ("2,210 Hz"). The person
   you are talking to is in the row, not the title.
5. There is no way to see **who a station is**: grid, when they were last
   heard, how strong. iMessage and Hops both open a contact card from the
   title.
6. The exchange strip reads like a form ("Their call" in a bordered
   field). iMessage's equivalent is a plain **To:** line.
7. Sent bubbles show a time and, when the echo was heard, a tick. Between
   sending and hearing back there is no word for the state. iMessage shows
   "Delivered"; Hops shows a short status under the last message.
8. Your own callsign in a received message is not highlighted, so "is this
   for me?" takes reading.
9. No haptic when a reply addressed to you arrives, and no notification
   when it arrives with the phone in your pocket, even though the receiver
   keeps decoding in the background.
10. Empty states explain, but do not offer the next action. Hops puts a
    "New Message" button in its empty state.
11. Settings' Audio section mixes the two things everyone touches (transmit
    frequency, clear-frequency) with four that only the receiver tuner
    touches, under a nine-line footer.
12. The conversation has no day separators, and nothing tells a new user
    that messages are short and public.

## Recommendations

### Conversation list

1. **Rename the tab to Messages**, bubble icon. Title the list "Messages";
   "Band" stays as the title of Everything mode, where it is accurate.
2. **Unread state.** Bold title and a teal dot for a conversation with
   received messages newer than the last time it was open. Badge the tab
   with the number of unread conversations. A conversation that is open in
   the foreground is always read.
3. **Messaging timestamps**: `HH:mm` today, "Yesterday", otherwise
   "3 Oct". All UTC, as before.
4. **Delivery glyph** before "You:" in the preview: sending, sent, heard.
5. **Empty state with the next action**: "Listen" when not listening,
   "Call CQ" when listening, plus one line setting expectations: messages
   are short, slow and public.

### Conversation

6. **Title is the station**, frequency as the subtitle. An empty
   conversation is "New message". Tapping the title opens the station card.
7. **Station card** (Hops' node card, Contacts-shaped): callsign with a
   monogram avatar, grid, last heard with signal, frequency, message count,
   and the actions Reply, Log contact and Look up on QRZ.
8. **"To:" line** instead of the bordered "Their call" field. Contest mode
   keeps Next and the serial number on the same line.
9. **Sent status words**: "Sending…", "Sent", "Heard +17 dB". Honest: "Sent"
   means the audio went out; "Heard" means the radio's monitor heard it.
10. **Highlight your callsign** in received messages.
11. **Day separators** when a conversation crosses a UTC day.
12. **Haptics**: a tap when you send, a success tap when a message
    addressed to you arrives.
13. **Notification** when a message addressed to you arrives with the app
    in the background. Permission is asked the first time you transmit,
    which is the first moment a reply matters.

15. **Recent stations under To:** a row of callsigns heard lately, this
    conversation's first, then the rest of the band, as Messages suggests
    recent contacts. One tap addresses a station; tapping again clears it.

### Settings

14. **Advanced audio page** for receive frequency, tolerance, whole-passband
    decoding and transmit level. The Audio section keeps transmit frequency
    and clear-frequency, with a short footer.

### Left for later

- Search across conversations and callsigns (Hops has a good model).
- Swipe actions on rows (Log contact, Hide) once hiding is in the model.
- Timestamps revealed by dragging, as in iMessage, instead of always on.
- Pinned conversations.
- A distance from your grid on the station card.

## Status

Recommendations 1 to 15 are implemented in this pass. The "Left for later"
items are not.
