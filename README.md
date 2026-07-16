# Drift Manager

Drift Manager is a Home Manager module that aims to be a convenient (and somewhat opinionated), way to handle dotfiles in nix that:
  1. Ensures reproducibility by guaranteeing that the tracked files are restored every time a Home Manager generation is activated.
  2. Keeps tracked files as ordinary, mutable files that can be modified 'on the fly' either by hand or by the software that uses them.
  3. Provides convenient mechanisms for managing configuration drift. Specifically:
     - a command line tool, `nix-drift`, to query changes, revert them, or generate a patch that can be applied to your dotfiles repo, and
     - notifications when manual changes have been overwritten that presents options to revert back to the modified configuration, discard manual configuration, or generate a patch for the changes.

## Status
This project is on indefinite hiatus because of an ongoing effort to deprecate activation scripts in NixOS. Since my design relies on activation scripts, that could be an issue. This may or may not affect Home Manager activation scripts, and either way there's probably a workaround using systemd. All the same, I'd rather see how this plays out over the next release or two.

In the meantime, [Chezmoi](https://www.chezmoi.io/) is an excellent project that handily accomplishes goals 2, and 3 among many other great features.
