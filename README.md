BuffMe (Project Lazarus)

BuffMe is a controller-driven, GUI-based buff dispatcher for the Project Lazarus EverQuest EMU server. It allows players to request buffs by sending a simple tell (for example, “buff me”) to your driver character, at which point your group automatically casts a predefined list of buff spells on the requesting player.

The script is designed to be Lazarus-safe, lightweight, and respectful of server performance. Only the driver runs persistently; group members execute a short-lived agent script on demand and exit immediately after casting.

Key Features

Tell-based buff requests

Any player can send a tell (default: buff me) to request buffs

Trigger phrase is configurable and case-insensitive

Controller-only GUI

Runs only on your driver character

No background scripts required on group members

Spell lookup and buff list editor

Search spells via a cached lookup

Add or remove spells from the buff list

Enable/disable individual buffs

Reorder buff priority

Persistent configuration

Buff lists and settings are saved to disk

No reconfiguration needed between sessions

Group-wide casting via broadcast

Automatically detects and uses:

E3Next (/e3bcga) if available

EQBC (/bcga) as a fallback

No DanNet dependency

Safe, short-lived agent execution

Group members:

Target the requesting player

Cast applicable buffs they know

Exit immediately after completion

Anti-spam protection

Per-player cooldown to prevent repeated requests

Lazarus-friendly design

No unsupported MQ calls

No continuous background polling on slaves

No invasive automation

How It Works (High Level)

The driver runs buffme.lua

A player sends a tell to the driver (e.g. "buff me")

The driver queues the request and broadcasts a command to the group

Each group member briefly runs buffme_agent.lua

Group members cast configured buffs they are able to cast

Agent scripts exit cleanly

Intended Use

BuffMe is ideal for:

Box groups

Static groups

Public buff characters

QoL automation without violating Lazarus scripting norms

It is not intended to replace full bot frameworks or unattended automation, and it intentionally avoids persistent slave logic.
