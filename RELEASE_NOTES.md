Build 23. Seven fixes since build 22, most of them found by running build 22 on an iPad — which is the argument for shipping early.

Fixed since build 22:
- Every invitation used to lead with a link that could not open. It pointed at tideandseek.invalid, a reserved domain guaranteed never to resolve, with no Associated Domain and no URL scheme behind it. Invitations now lead with the six-digit code, which is what you actually type.
- The onboarding card showed the Skipper glyph captioned "Lead" — the road group-riding role this app was scaffolded from. Skipper everywhere now. The relay was pinning the old spelling and would have rejected every crew payload once the app changed, so both sides accept both.
- A sailor name was mandatory before the app would open, and "Skip tour" did not skip it. So a solo-first app made you name yourself for a crew you may never have. Optional now: leave it blank and you sail as Skipper.
- Onboarding used to end on "Create a voyage" or "Join a voyage", both crew activities. "Sail on my own" is now the first option, and screen one says what the app does alone — plus a card stating plainly that this is not a chart and the courses are unchecked.
- Choosing to sail alone then showed "Waiting for the skipper's route", to a sailor with no voyage and no crew. Gone.
- The launch screen was Flutter's placeholder: a transparent pixel on white, so a dark app flashed white on every launch. It is the yacht from the app icon now, on the app's own background.
- A mark added to an imported passage could not be removed — the delete button was gated on a flag that is false for exactly those passages. Marks can now be named too, and a name survives GPX.

Worth trying on this build:
- On the iPad in landscape, open a passage for review: the chart now sits beside the leg table instead of above it, both full height. This is the layout I could verify in tests but not on a running device — please tell me if it reads wrong.
- Setup with no name at all, then "Sail on my own".
- The demo passage (Lymington to Cowes, 5 marks, 4 legs, 8.6 NM), its leg table, and adding then naming then removing a mark.
- Navigation instruments under way. Still the thing that most needs a real GNSS fix — the simulator has none, so nothing in it has been seen with live values.

Still deliberately absent: tides, tidal streams, charted depth, wrecks and obstructions. The free UKHO data may carry a field-of-use restriction that blocks a navigation app and that question is unanswered. With no tide, a passage this plans is a passage in still water. Not a substitute for an official chart.
