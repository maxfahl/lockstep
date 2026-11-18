# Lockstep icon ideas

Three ideas for the app icon, drawn with code in the app's colours (accent #8A8FFF on the window colour #0B0B0E). Each has a large picture (1024 by 1024) and a small one (64 by 64) to judge how it reads in the Dock and in Finder.

- **On the beat** (`on-the-beat-1024.png`, `on-the-beat-64.png`): a short voice waveform whose five syllables swell exactly on five evenly spaced beat lines.
- **In step** (`in-step-1024.png`, `in-step-64.png`): four accent syllables, each standing over one of four grey beat dots, like two rows walking in lockstep.
- **Round the bar** (`round-the-bar-1024.png`, `round-the-bar-64.png`): a waveform bent into a ring, one bar going round, swelling towards the four beats shown as bright dots.

To make the pictures again, from the repository root:

    swift docs/design/icon/make-icons.swift

Max chose **In step** on 13 November 2026. The same command also writes it at the ten sizes macOS needs (16 to 512 points, at 1x and 2x) into `Lockstep/Resources/Assets.xcassets/AppIcon.appiconset`, which only the Lockstep app uses. To change the chosen idea, change `chosen` near the end of the script.
