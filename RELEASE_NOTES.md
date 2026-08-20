Build 25. You can now sail the passage, not just plan it — and a fitness review found three places where the app was quietly telling you the wrong thing.

The one worth knowing about first. Importing a passage as a GPX with a <rte> element — how every plotter exports one — used to say: "Directions could not be built for this route. Re-import it to try again." That was false, and re-importing would have produced the same message forever. The passage was fine; it simply has no turn-by-turn, by design. Fixed.

Under way, the banner now reads the passage instead of saying nothing useful:

  Leg 1 of 3 to Hamstead
  3.4 NM to run · then alter 26° to port onto 068°T

  Approaching Hamstead
  6 cables to run · then alter 26° to port onto 068°T

  Arriving at Cowes
  5 cables to run · last mark of the passage

And it speaks. At a mile off a mark, and again at two cables: "6 cables to Hamstead, then alter 26 degrees to port onto zero six eight." The speech stack has been complete since before the rename and had never had a phrase to say, because it was fed from a road manoeuvre list that is always empty on a passage.

Courses are spoken digit by digit — "zero six eight", never "sixty eight", which through wind noise could be 068 or a careless 268. Distances are cables inside a mile, never with a decimal.

Three things it deliberately will not do:
- Off track, it tells you which side and gives the leg's own course. It will not compute a course to steer back — that would be the app choosing a course with no chart, no depth and no tide under it.
- A stale fix outranks an approaching mark. Two cables off on a three-minute-old position, the mark is not the thing to say.
- No prompt says turn, steer, or head for. "Alter 26 degrees to port" reports the plan you made, at the moment it matters.

Also: there were two manoeuvre lists, and the one the map menu opened was the empty road one — gated on road manoeuvres, so the menu item never appeared at all. One list now, and it is reachable.

Worth trying on this build:
- Load the demo passage, start the voyage, and watch the banner as you move. It changes at a mile and again at two cables.
- Turn the voice on. It should say the mark and the alteration once, not once per fix.
- The ⋮ menu on the map now offers "All alterations on this passage".
- Try importing a passage from your own plotter, if you have one. That is the path that was broken and I have no real file to test against.

Still deliberately absent: tides, tidal streams, charted depth, wrecks. The UKHO licence question is unanswered, so a passage this plans is still a passage in still water. Not a substitute for an official chart.

Two things I could not verify and would value your eyes on: the under-way banner on a real device with a real fix — the simulator has no GNSS and I could not get a voyage started there — and the iPad landscape layout, which is pinned by tests but has never been seen on an iPad.
