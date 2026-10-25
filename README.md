# BAR Advisor

A voice advisor widget for [Beyond All Reason](https://www.beyondallreason.info/). It watches your own units and
income and reminds you, by voice, of things that are easy to forget mid-game: idle constructors, teching up, anti-air
and an anti-nuke.

It is meant for remembering, not as orders: every reminder is something a good player would have thought of anyway.
It plays sounds and prints a console line, and nothing else. It gives no orders and reads only what you can see
yourself (your own units and income), so it can be used wherever user widgets are allowed, including multiplayer.

## Reminders

| Reminder | Comes up when | Repeats every |
| --- | --- | --- |
| Commander idle | the commander has had no orders for 30 s | 30 s |
| Tech 1 constructor idle | a tech 1 constructor has had no orders for 30 s | 30 s |
| Tech 2 constructor idle | a tech 2 constructor has had no orders for 30 s | 30 s |
| Consider tech 2 | metal income has held at 30/s or more for 60 s, or 14 minutes have passed, and no tech 2 factory is started | 120 s |
| Consider tech 3 | a tech 2 factory is finished, metal income has held at 90/s or more for 60 s, and no tech 3 factory is started | 120 s |
| Build anti-air | from minute 5, while you have fewer than 2 anti-air units | 60 s |
| Build anti-nuke | from minute 25, or once metal income has held at 80/s or more for 60 s, until an anti-nuke has a missile ready | 60 s |

Guarding or assisting counts as an order, so a constructor helping a factory is not idle. Nano turrets are never
reported: they often wait behind the front as repair stations on purpose.

Income thresholds must hold for 60 s, because reclaiming a wreck makes income spike for a moment. They are chosen so
that the next step costs about 90 s of income: a tech 2 lab (2600 metal) at 30 metal/s, an Experimental Gantry
(8000 metal) at 90 metal/s. The anti-nuke threshold is the income at which an equal opponent could afford a nuke.

Only one announcement plays every 10 s. When several reminders are due, the one that is most overdue (time past its
own interval) plays and the others wait for later slots, so no reminder can crowd out the rest.

## Install

1. Clone this repository into `LuaUI/Widgets/` of your BAR data directory:
   ```
   cd <BAR data dir>/LuaUI/Widgets
   git clone https://github.com/backbone81/bar-advisor.git
   ```
   so that you get `LuaUI/Widgets/bar-advisor/snd_advisor.lua`. (Without git: download the repository as a zip and
   unpack it to the same place.)
2. Start BAR, open the widget list (F11) and make sure "Advisor" is enabled.

To update, run `git pull` in `LuaUI/Widgets/bar-advisor/`.

BAR loads every `.lua` file in a folder directly under `LuaUI/Widgets/` as a widget, and nothing deeper. So the
repository root holds only the widget; its voice lines and the script that makes them are in `sounds/`.

The widget removes itself while you spectate a live game. When you watch a replay it stays silent and only writes
`[reminder]` lines to the log (see Testing).

## Settings

All thresholds are constants at the top of `snd_advisor.lua`, e.g. `IDLE_SECONDS`, `TECH2_METAL_PER_SECOND`,
`ANTIAIR_MINUTES`, `VOLUME` (0.7 like BAR's own voice notifications; at most 1.0). Edit them there and reload the
widget.

## Voice lines

Each reminder plays a voice line from `sounds/`, named after what it says (e.g. `sounds/build_anti_air.wav`). If a file
is missing, a game sound plays instead. How the lines were made and how to re-create or change one is described in
[`sounds/README.md`](sounds/README.md).

## Testing

When you watch a replay with the widget enabled, it follows every team (each player and each AI has one; Gaia, the
map's neutral team, is left out) and, instead of playing sounds, logs a line per announcement to `infolog.txt` in your
BAR data directory:

```
[reminder] f=<frame> team=<teamID> ai=<0|1> key=<key> idle=<idle builders> name=<player or AI name>
```

The lines show how often each reminder would have played for each team in that game. To see them for one team:

```
grep "\[reminder\].* team=0 " infolog.txt
```
