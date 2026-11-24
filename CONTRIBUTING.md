# Contributing

Issues and pull requests are welcome.

## Before you open a pull request

[Test](README.md#test) in the README explains both test setups. CI runs them on every pull request, so you don't need an arm64 machine.

To run them yourself:

```sh
test/run.sh                                # needs Docker on an arm64 machine
test/emulator/run.sh /path/to/koreader-dev  # in KOReader's desktop emulator
```

Keep a pull request to one change.

## Pull request titles

Pull requests are squash-merged, so the title becomes the commit on `main`. Titles follow [Conventional Commits](https://www.conventionalcommits.org/), and a check enforces it:

| Title | Release |
|---|---|
| `fix: handle an empty config` | patch (0.3.1 → 0.3.2) |
| `feat: add a dark theme` | minor (0.3.1 → 0.4.0) |
| `feat!: drop the old config format` | breaking: minor while below 1.0, major after |
| `docs:`, `test:`, `refactor:`, `ci:`, `chore:` | none |

A scope is optional: `fix(auth): …`. Mark a breaking change with `!` after the type.

## Releases

Releases are automatic. [release-please](https://github.com/googleapis/release-please) keeps a pull request open with the next version and changelog; merging it tags the release, and CI builds and publishes it.

Don't edit the version in `_meta.lua` by hand; the release pull request updates it. Test reports from real e-readers are very welcome as issues.

## License

By contributing you agree that your contribution is licensed under the project's license, MIT ([LICENSE](LICENSE)).
