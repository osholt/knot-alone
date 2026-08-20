Build 26 is the first marine-context tester build.

The underway chart now starts flat and farther out. Pan, pinch, rotate, plus and
minus put the view under your control; Follow vessel brings it back in one
action.

New context on the chart:

- calculated astronomical tide heights and curves for Lymington, Portsmouth
  and Southampton, bundled for offline use and labelled non-official;
- a time-selectable Open-Meteo area wind forecast with arrows, speed, gust,
  valid time and attribution; and
- received AIS targets from an existing boat-local NMEA TCP receiver. With no
  receiver configured, the chart menu offers an unmistakably synthetic replay.

The new MOB control records the best position available, fixes the marker on the
chart and shows elapsed time, bearing and distance. Ending it requires an
explicit recovered or false-alarm choice. It does not transmit a distress alert
and the marked position does not move with a person in the water.

The last inherited road-routing, roundabout and lane-guidance stack has also
been removed. Passage guidance now comes only from the passage marks and legs.

Please try:

- pan and zoom while sailing, then use Follow vessel;
- compare the three tide stations with a source you already trust;
- step the wind forecast backward and forward;
- exercise MOB somewhere safe, including with no useful fix; and
- if you already own a compatible AIS receiver, follow
  docs/ais-local-receiver.md and report the receiver model and reconnect
  behaviour.

Important: this is still not a licensed nautical chart and has no soundings,
depth contours or tidal streams. AIS is incomplete and is not a collision
alarm. MOB, tides and local AIS still need physical-device and on-water
validation. Do not rely on this build for navigation or casualty recovery.
