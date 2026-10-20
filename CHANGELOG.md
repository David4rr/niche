# changelog

## 0.6.6

- volume and brightness keys no longer freeze the keyboard or bring back the macOS popup. niche kept piling up volume listeners every time the output device or a live activity setting changed, so after a while one key press ran hundreds of volume reads at once. they now come off properly, and the volume and brightness changes themselves run in the background.
- memory: about 18 mb after launch (19 mb in 0.6.5). the download stays 2.4 mb.

## 0.6.5

- the noise control activity works: niche follows the same change that makes macOS show its own noise control banner, so switching modes from control center or the stem now shows in the notch. taking a bud out (which also switches the mode) doesn't.
- the noise control icons are apple's own, the same ones as the listening mode menu: a ringed head for noise cancellation, a dotted halo for transparency, sparkles for adaptive, a plain head for off.
- memory: about 19 mb after launch, same as 0.6.4 measured side by side. the download stays 2.4 mb.

## 0.6.4

- the music player is more compact: a narrower open notch, smaller title and artist, and a thicker progress bar tinted with the artwork's colours.
- the repeat button is replaced by the output device: macbook speakers, headphones, airpods, a homepod or other speaker. clicking it opens a volume slider under the controls; the speaker on its left mutes. while the slider is open, volume changes don't pop the volume activity.
- every control reacts: a soft square under the hovered button and a small squash when pressed. skip slides one arrow out and a new one in, play and pause shrink into each other, and shuffle lifts with a dot under it when on.
- a new song flips the cover: the old one folds to a sliver and the new one unfolds from it, blurred, then sharpens.
- the open agents list is only as tall as its sessions. with more than 4, clicking "+n more" grows the notch to show them all, and "show less" folds it back. the status pill no longer gets cut off.
- airpods live activities: connecting drops the buds in with a little tilt and sweeps a battery ring to the lowest bud's charge, disconnecting dims them and draws a slash with "off". a noise control change shows the new mode (noise cancellation, transparency, adaptive, off), and a bud dropping to 20 % and 10 % shows a pulsing red ring. each has its own switch under settings, live activities. niche asks for bluetooth permission once for this.
- the brightness activity only shows after a brightness key press. the screen dimming by itself (idle dim, auto-brightness, unplugging) no longer pops it.
- battery activities (charging, fully charged, low battery) get a slightly wider right ear, so "100%" no longer runs into the notch's edge.
- the clipboard is out of the feature switcher: it only opens with its shortcut (control-command-v). hovering never opens it.
- memory: about 20 mb right after launch, the airpods watcher adds no measurable cost. the download is 2.4 mb (2.3 mb in 0.6.3).

## 0.6.3

- niche takes over the brightness keys again, so the system brightness popup is gone and only the notch shows the change.
- brightness now fades smoothly and stays where you put it. niche asks macOS for the same gentle step the brightness keys use, instead of setting the screen directly like before 0.6.2.

## 0.6.2

brightness fix.

- the brightness keys go back to macOS. niche used to set the screen brightness itself, which jumped instead of fading, and macOS could then fade it back to its own level, which could leave the screen stuck dark. now brightness fades smoothly and stays where you put it.
- the notch still shows the brightness change. macOS may show its own brightness popup again; the volume popup is still replaced.

## 0.6.1

- the feature switcher animates now: the front circle hops and slides to the back while the next one comes forward.
- switching no longer blanks the whole open notch for a moment. the current view blurs and slides out while the next one slides in, and the top row stays put.
- changing songs quickly no longer drops the notch to its empty state. a blank now-playing update between songs is ignored unless nothing plays for 1.5 s.

## 0.6.0

one switch.

- the open notch's top row is down to just the feature switcher. the clipboard mark and the claude and omp marks are gone from it.
- the switcher now cycles through music, agents and the clipboard. music and agents switch for real, so the closed notch follows; the clipboard is still only a peek, and moving away goes back to what you were on.
- the agents view lists every running session, claude and omp together, each row starting with its agent's mark and its working or waiting dot.
- ⌃⌘V still opens the clipboard straight away.

## 0.5.9

- the volume and brightness bar is longer, and the notch grows a little on the right while it shows, so the bar sits as far from the right edge as the icon does from the left.

## 0.5.8

- the open padlock is more compact: its shackle is shorter and narrower once it swings open, and pops up less, so the unlocked lock is about the same size as the locked one.

## 0.5.7

- with two kinds of agent running, the closed notch now grows only on the side that needs room, instead of both. the picture side keeps its usual width, and nothing sits under the camera anymore.
- the open notch is a little wider, so the agent marks and the switcher sit in the right ear clear of the camera. the clipboard mark moved to the left ear.

## 0.5.6

- the claude and omp marks in the closed notch are the same size now, and the status dots sit at the same spot on each.
- the agent marks no longer crowd the notch's edges. with more than one kind of agent the notch widens a little, with or without a notch picture.

## 0.5.5

- without a notch picture, the closed agent view is back to its usual look: the agent marks on the left, one working or waiting dot and the count on the right, at the normal width.
- with a picture set, it stays as in 0.5.4: the picture on the left, each agent with its own dot on the right.

## 0.5.4

- the notch picture now sits exactly like the song artwork: 24 pt, with the same 5 pt gap on the left and underneath.
- with more than one kind of agent running, the closed notch widens a little so claude and omp sit side by side, each with its own working or waiting dot, then the count.

## 0.5.3

five notch pictures built in.

- settings, under general, now has five of niche's own little pixel gifs to pick with one click: pyramid head, a cat, a ghost, a cassette and a campfire. your own picture or gif still works with choose.
- the built-ins come inside the app, about 30 kb for all five.
- the agent marks in the closed notch now overlap the right way, claude half behind omp.

## 0.5.2

- the song artwork in the closed notch now has the same gap on the left and underneath, 5 pt each.

## 0.5.1

- the song artwork in the closed notch sits a little further in from the edge, 6 pt instead of 4.

## 0.5.0

a picture for the empty notch.

- pick a picture or gif in settings, under general, and it sits on the left of the notch whenever nothing else is showing. gifs keep their own speed.
- everything else works the same: music, agents, live activities and the lock screen still take its place, and hovering behaves as before.
- niche keeps its own copy of the picture, so moving or deleting the original changes nothing. each frame is shrunk once to the notch's size, so even a big gif costs almost nothing.
- it shows at 26 pt, a little bigger than the song artwork. empty space around the art is trimmed so it fills the slot. best at 64 × 64 px or larger, square, with a transparent background.
- the song artwork in the closed notch is bigger, 24 pt instead of 20, with the same gap on every side and corners that follow the notch's curve.
- with only agents running, the closed notch shows your picture on the left and a compact agent cluster on the right: claude and omp stacked, a dot for working or waiting, and the count.
- live activities sit 2 pt higher, so they look centred in the notch instead of low.
- memory: about 23 mb right after launch with a gif set and an agent running. the download is 2.3 mb.
- browsers no longer count as music. a paused tab, or a page that only touched the media controls, used to take over the notch as a song with no artist.

## 0.4.1

lighter clipboard.

- copied images, file icons and app icons are now kept as small pictures drawn once, instead of the full image being kept and redrawn every time the clipboard opens.
- memory: about 21 mb right after launch. the first time the notch opens it settles around 33 mb with a full history, and then stays there however often you open it.

## 0.4.0

clipboard.

- niche now remembers your last 10 copies: text, links, colors, images and files. it shows them in the notch as tiles, all at once, no scrolling. hover a tile to read it in full, click to put it back.
- press ⌃⌘V anywhere to open it from the keyboard: 1 to 9 picks one, arrows and return work too, and esc closes it. with accessibility allowed, picking pastes straight into the app you were typing in.
- every copy shows a quick glance in the notch with the app it came from and what was copied, a color shows its swatch and an image its thumbnail.
- copies stay on your mac, in memory only, and are gone when niche quits. passwords from password managers are skipped.
- the clipboard has its own pane in settings: how many to remember (3 to 10), the shortcut, paste on pick, and clear history.
- memory: about 21 mb when idle, about 29 mb with a full history of 10 that includes an image. images keep only a small thumbnail on screen. the download is 2.3 mb.

## 0.3.7.4

- the padlock's shackle is taller, so it reads as a lock at a glance.

## 0.3.7.3

- the volume, brightness and lock icons in the notch are smaller, so they sit in proportion with the artwork and the level bar.

## 0.3.7.2

- locking is no longer instant: the open padlock blurs in, holds for a beat, then the shackle swings over and snaps shut.

## 0.3.7.1

- the padlock shackle now swings open around its right leg, like a real padlock, instead of lifting out of the middle and sliding over. locking swings it back the same way.

## 0.3.7

a padlock that clicks.

- on unlock the padlock ducks, the shackle pops up with a spring and swings open to the side. on lock it swings back and snaps shut with a small bounce.
- the padlock is back to the size of the system lock icon.

## 0.3.6

a smoother padlock.

- the lock screen padlock is drawn by niche now. on lock it fades in open and its shackle drops shut.
- on unlock the shackle lifts and swings open, then the padlock blurs away before the music or agents come back, instead of popping between icons.

## 0.3.5.1

- the brightness sun now grows with the level: its rays light up one by one and get longer, sliding smoothly like the volume icon.

## 0.3.5

smoother live activities.

- activities now blur and fade out when they end, instead of vanishing, and then the music or agents come back.
- volume and brightness slide between levels instead of jumping, and their icons fill in with the level.

## 0.3.4

agent marks stay put.

- the agent marks sit on the right next to the feature switcher in every mode, instead of jumping to the left when agents are open.

## 0.3.3

agent marks peek instead of switching.

- clicking an agent mark in the open notch shows its sessions just for that look. move away and the notch goes back to what it was showing, music stays music.
- only the feature switcher on the right changes what the notch shows.

## 0.3.2

a new icon.

- the app icon is now a dark screen with the notch, framed in white.
- the menu bar shows the same notch shape instead of the word niche.
- the download is smaller again, 2.2 mb instead of 3.4 mb.

## 0.3.1

a proper welcome and an icon.

- first launch opens a short welcome: allow accessibility and choose whether niche opens at login. nothing else is needed.
- open at login is also in settings, under general.
- niche has its own icon now, a black hole, made for the macos 26 icon style with light, dark, clear and tinted looks.
- plugging in or unplugging the charger no longer pops up the brightness bar when macos adjusts the brightness by itself.
- the icon makes the download bigger, about 3.4 mb instead of 231 kb. memory is unchanged, about 20 mb when idle.

## 0.3.0

live activities.

- short popups in the notch for caps lock, focus, volume, brightness, low battery, charging, fully charged and when an agent finishes. each one can be turned off in settings.
- with accessibility allowed, niche takes over the volume and brightness keys so the system popup no longer shows. macos still shows its own focus banner, that one can't be hidden.
- activities also show when the notch is open, and the notch grows a little to fit them.
- the open notch is a bit bigger with larger artwork and controls, and the closed notch is slimmer.
- music shows up again after the notch was stuck on agents, and it switches back to music when something starts playing.
- the closed agent view shows a plain mark without the extra dot.
- niche is now signed with a stable identity, so permissions stick across updates. you may need to allow accessibility once more after this update.

## 0.2.1

agents show up again.

- omp sessions started with `--resume` were missed, so the agent mark and list stayed empty. they are picked up now and clicking one still jumps to its tmux pane.
- a session that had exited no longer blocks a live one in the same folder from showing.

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
