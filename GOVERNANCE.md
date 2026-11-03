# Governance

nimgrpc is a small project with one active maintainer (the owner of the repository) and a backup maintainer who can continue it. This file says how it is run, so that a contributor knows what to expect and a user knows what the controls are.

## Members and roles

| Member | Role | Access to sensitive resources |
|---|---|---|
| `zystem` (the owner) | maintainer: decides, reviews and merges, makes releases, answers security reports, holds the settings of the repository | write access to the repository and its settings, the secrets of the CI (none today) |
| `Juliesergienko` (backup maintainer) | keeps the project going if the owner cannot: merges pull requests, makes releases (a tag `vX.Y.Z` and its GitHub release), answers security reports | write access to the repository (no access to its settings or to the account of the owner); can edit the project's entry on bestpractices.dev |
| contributors | anyone who sends a pull request or an issue | none |

This is the complete list of members with access to sensitive resources; it is changed in this file when a permission is granted or removed.

## How the project is run

- **Decisions** are made by the maintainer, in the open: in issues and pull requests, with the reasons in the commit message or in `docs/`.
- **Contributions** come as pull requests and follow [CONTRIBUTING.md](CONTRIBUTING.md).
- **Escalated permissions** (write access to the repository, the settings, the secrets of the CI) are given only to a person who has contributed accepted changes over time, whose identity is known to the maintainer, who uses two-factor authentication, and who has been reviewed by the maintainer before the permission is granted. The maintainer reviews the list of collaborators when a release is made and removes those who are no longer active. The only collaborator today is the backup maintainer above, who was given write access by the owner on the conditions of this paragraph (identity known to the owner, two-factor authentication); the owner is the only one with access to the settings.
- **Continuity**: the backup maintainer can do everything a release needs: merge a pull request into `main` (protected, with the checks that every change passes), push a tag `vX.Y.Z`, create the GitHub release with the notes of [CHANGELOG.md](CHANGELOG.md), and read private vulnerability reports. The steps are in [docs/releasing.md](docs/releasing.md); nothing in them needs a secret that only the owner holds (the CI has none, nothing is signed). If the owner is gone, the backup maintainer decides as the owner does until another maintainer is chosen.
- **Releases** are tags `vX.Y.Z` created by the maintainer (or the backup maintainer), signed with an SSH key (see [SECURITY.md](SECURITY.md#verifying-a-release)); a backup maintainer who makes a release adds their own key to `docs/allowed_signers` in a pull request first. The library is distributed as source (nimble); there is no binary to sign.
- **Review of changes**: the maintainer is the only author today, so a change to `main` is not approved by a second person; it is checked by the automatic gates instead (tests, sanitizers, dependency review, secret scanning, see [docs/security-policies.md](docs/security-policies.md)). The backup maintainer does not review changes routinely. When a second active maintainer joins, review by a person other than the author becomes required (branch protection).
- **Security reports** go as in [SECURITY.md](SECURITY.md).
