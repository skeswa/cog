# Fixture scenarios: an exit test proven only in debug

`TURN-07`'s marker is wrapped mid-phrase, the way the real tree wraps it, so a
parser that read raw lines instead of the whole scenario body would miss the
mode entirely and this fixture would go quiet.

- **TURN-01.** The writer stages a value and reads it back.
- **TURN-07.** I sneak the writer out of the turn and use it after the turn
  ended. Cog stops me with an error, in every kind of build. (Proof: exit
  test.)
