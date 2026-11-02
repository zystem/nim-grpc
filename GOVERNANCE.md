# Governance

nimgrpc is a small project with one maintainer (the owner of the repository). This file says how it is run, so that a contributor knows what to expect and a user knows what the controls are.

## Members and roles

| Member | Role | Access to sensitive resources |
|---|---|---|
| `zystem` (the owner) | maintainer: decides, reviews and merges, makes releases, answers security reports, holds the settings of the repository | write access to the repository and its settings, the secrets of the CI (none today) |
| contributors | anyone who sends a pull request or an issue | none |

This is the complete list of members with access to sensitive resources; it is changed in this file when a permission is granted or removed.

## How the project is run

- **Decisions** are made by the maintainer, in the open: in issues and pull requests, with the reasons in the commit message or in `docs/`.
- **Contributions** come as pull requests and follow [CONTRIBUTING.md](CONTRIBUTING.md).
- **Escalated permissions** (write access to the repository, the settings, the secrets of the CI) are given only to a person who has contributed accepted changes over time, whose identity is known to the maintainer, who uses two-factor authentication, and who has been reviewed by the maintainer before the permission is granted. The maintainer reviews the list of collaborators when a release is made and removes those who are no longer active. Today there are none besides the maintainer.
- **Releases** are tags `vX.Y.Z` created by the maintainer. The library is distributed as source (nimble); there is no binary to sign.
- **Review of changes**: the maintainer is the only author today, so a change to `main` is not approved by a second person; it is checked by the automatic gates instead (tests, sanitizers, dependency review, secret scanning, see [docs/security-policies.md](docs/security-policies.md)). When a second maintainer joins, review by a person other than the author becomes required (branch protection).
- **Security reports** go as in [SECURITY.md](SECURITY.md).
