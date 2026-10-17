# changelog

## 0.2.0

lighter on memory and on download.

- fixed memory that kept growing while the notch was open. it used to climb past 50 mb, now it settles around 30 mb open and 18 mb closed.
- artwork is kept as a small thumbnail and decoded once per song instead of on every update.
- the settings window frees its memory when you close it.
- the time labels no longer animate every second, which was a big part of the growth.
- the app is built for size: 1.7 mb down to 650 kb, and the download from 504 kb to about 360 kb.

## 0.1.2

a fix for stale artwork.

- after quitting the music app and playing something else, the closed notch kept showing the old album until you opened it. it now switches to the new one right away.

## 0.1.1

smoother notch when things come and go.

- the notch now grows when music or an agent shows up, and shrinks back when it ends, evenly from the middle instead of jumping between sizes.
- the artwork and agent marks blur in and out with it instead of vanishing on the spot.

## 0.1.0

first release. niche turns the notch into a small dynamic island.

- music: artwork, title, controls and a seek bar, with waveform bars beside the notch. bars that follow the actual audio are optional.
- agents: running claude code and omp sessions show up with whether they are working or waiting on you. click one to jump to its tmux pane and terminal tab.
- switch between music and agents from the right side of the open notch.
- a padlock sits by the notch on the lock screen and opens when you unlock.
- settings have a page per feature.
- updates show up in settings with what changed, and install in one click.
