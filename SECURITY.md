# Security policy

AI Cache Cleaner deletes files, so safety bugs matter more than anything else here. Thank you for looking.

## Reporting a vulnerability

Please report privately through GitHub: open the [Security tab](https://github.com/AlienEmperor604/OopSI/security) of this repository and click **Report a vulnerability**. Don't open a public issue for security problems.

Useful things to include:
- what you ran (app, `-Clean`, `-AutoClean`, `-Install`) and on which Windows version
- the folder layout that triggers it (a small script that recreates it is ideal)
- what was deleted or touched that shouldn't have been

You'll get a reply as soon as possible. Fixes ship as a new release, with credit if you'd like it.

## What counts

Anything that breaks one of the guarantees in the README's [Safety & security](README.md#safety--security) section, for example:
- deleting something outside the listed caches, or a file that a running program needs
- following a junction or symlink and touching its target
- running code from a folder an attacker could write to (binary planting, PATH tricks)
- the scheduled task running with more rights than the current user

## Supported versions

Only the latest release gets fixes.
