# Contributing to FlowDroid

Thanks for your interest. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue and include:

- what you did, what you expected, and what happened instead;
- your phone model and Android version;
- if a workflow is involved, a copy of it (in the editor, copy the workflow
  as JSON). Remove any personal data first.

Security problems should not go in a public issue. See [SECURITY.md](SECURITY.md).

## Suggesting a feature

Open an issue describing the problem you want to solve, not only the feature.
"I want to be told when my parcel ships" helps more than "add an email
parser", because there may be a simpler way to get there.

## Making a change

1. Set up the tools listed in the [development guide](docs/development.md#build).
2. Create a branch from `main`.
3. Make your change, with tests.
4. Run `make check`. It runs everything CI runs: the TypeScript tests, Rust
   formatting, lints and tests, the Rust-matches-TypeScript proof, and the
   Flutter analyzer and tests.
5. Open a pull request that explains what changed and why.

### Changing the workflow engine

The engine exists twice: the TypeScript version in `engine-ts/` is the
specification, and the Rust version in `core/flowcore-engine/` is what ships.
Change the TypeScript first, then port the change to Rust, then run
`make port-verify` to prove the two still agree on every recorded case. The
[development guide](docs/development.md#changing-the-engine) has the details.

### Style

- Dart: `dart format` with a 120-character line width, and no analyzer
  warnings.
- Rust: `cargo fmt` and `cargo clippy` with warnings treated as errors.
- Text the app shows people should be short, plain and specific: say what
  happened and what to do next.
