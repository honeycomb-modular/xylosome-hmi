# Note for the Capture PC (from the dev PC, 2026-09-02)

Read me on startup, then this note can be deleted or kept as reference.

## Sibling repos exist - clone them

The robot projects that live on the dev PC are on the same
honeycomb-modular GitHub account this repo uses. Your stored git
credential already has access - no setup needed:

    cd C:\dev
    git clone https://github.com/honeycomb-modular/therasome-01.git
    git clone https://github.com/honeycomb-modular/motionbox.git
    git clone https://github.com/honeycomb-modular/mnemosome.git

- **therasome-01** - the film-set robot platform: founding brief,
  concept docs, a 24-rule behavior constitution
  (concepts/therasome-rules.md), mule prototype build notes.
- **motionbox** - the motor/EtherCAT bench proving the architecture
  (2x RobStride on CANopen, depth-camera-driven demos). Read its
  CLAUDE.md: it deliberately never touches xylosome machines.
- **mnemosome** - the knowledge library behind a local AI
  (plain-file docs + cards + sync tooling). Its library/confidential/
  tier is gitignored by design - never add NDA material to git there.

## Why you saw a 404 on GitHub (2026-09-01)

The repos are PRIVATE under the honeycomb-modular ACCOUNT (not an org).
This machine's git uses that account's credential, but the BROWSER
login was a different account -> GitHub shows private repos as 404 to
outsiders. Nothing was ever missing. Browser fix: log into github.com
as honeycomb-modular, or add the personal account as collaborator.

## Habits now that two PCs share these repos

git pull before working, git push when stopping. The dev PC does the
same. Divergent work on the same files = merge conflicts = avoidable.
