# Launch screen

`LaunchImage*.png` is the sailing yacht from the app icon, in the icon's cream
(#F9F0DD) on transparency, at 160pt tall. It is generated from
`AppIcon.appiconset/Icon-App-1024x1024@1x.png` by masking to that cream — the
motor cruiser is pale green and the chevrons yellow, so a cream threshold
isolates the yacht — cropping to its bounding box and resampling the alpha
rather than a coloured bitmap, which keeps the rigging from picking up a green
fringe.

The storyboard paints `#0D1117` behind it, the app's `scaffoldBackgroundColor`.
It used to be white, so every launch of a dark app flashed white first.

Regenerate from the icon rather than editing these by hand, so the launch screen
cannot drift away from the icon it is taken from.
