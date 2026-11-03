# Making a release

For a maintainer (the owner or the backup maintainer, [GOVERNANCE.md](../GOVERNANCE.md)). A release is a signed tag `vX.Y.Z` on `main` and a GitHub release with the notes of that version. The library is distributed as source: nimble takes the tag from the repository (the entry `nimgrpc` in the [nimble directory](https://github.com/nim-lang/packages) points at it), so there is no binary to build or sign and nothing needs a secret that only one person holds.

## Before

1. `main` is green: the checks of the last run on it (tests plain and under AddressSanitizer on both Nim versions, `nimble lint`, CodeQL, Dependency Review), and nothing is open that must go in. `git checkout main && git pull`.
2. Read the advisories of nghttp2, BearSSL and zlib since the last release ([security-policies.md](security-policies.md)); a Critical or High finding with a fix is fixed first.
3. Choose the number ([Semantic Versioning](https://semver.org/); while the version is 0.x a break of compatibility or a new default is the second number, a fix or a change of documents only the third). Read what has gone in: `git log vPREV..main --oneline`.

## The release pull request

4. A branch `release-X.Y.Z`. In `CHANGELOG.md` the heading `## Unreleased` becomes `## X.Y.Z — DATE` (and a new empty `## Unreleased` stays above it); what is missing is added, user-visible changes only, security fixes with their identifiers. In `docs/upgrading.md` the same: what a user must do to move to this version goes under `## X.Y.Z`. In `nimgrpc.nimble` the `version` is raised.
5. `git commit -s` (every commit carries a sign-off, [DCO.md](../DCO.md)), push, open the pull request, wait for the checks, merge.

## The tag

6. `git checkout main && git pull`. A signed annotated tag (the signature is made by the setting below): `git tag -a vX.Y.Z -m "nimgrpc X.Y.Z"`. Check it: `git -c gpg.ssh.allowedSignersFile=docs/allowed_signers tag -v vX.Y.Z` must say `Good "git" signature`. Push it: `git push origin vX.Y.Z`.
7. The GitHub release, with the notes made from the changelog:

   ```bash
   tools/release_notes.sh X.Y.Z > /tmp/notes.md
   gh release create vX.Y.Z --title "X.Y.Z" --notes-file /tmp/notes.md --verify-tag
   ```

## After

8. Check as a user would, in an empty directory: `nimble install nimgrpc@X.Y.Z` (the nimble directory finds the tag by itself; if it does not, `nimble refresh`), then a `import nimgrpc` program compiles. On GitHub the tag shows "Verified".
9. If something is wrong with a release, do not move or delete the tag: fix it on `main` and make the next release, and say what was wrong in its notes.

## Setting up the signature of a tag (once, per maintainer)

```bash
git config --local gpg.format ssh
git config --local user.signingkey ~/.ssh/KEY.pub   # your public key (the private one in ssh-agent or without a passphrase)
git config --local tag.gpgSign true
```

Add the public key to your GitHub account as a **signing key** (Settings → SSH and GPG keys → New SSH key → Signing Key), so that the tag shows "Verified", and add it with your GitHub-noreply address to [allowed_signers](allowed_signers) in a pull request, so that [SECURITY.md](../SECURITY.md#verifying-a-release) can tell users how to check your tags. A change of key is announced in the release notes.
