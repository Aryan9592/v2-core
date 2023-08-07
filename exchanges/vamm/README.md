# Voltz V2 - VAMM

## Prerequistes

- Install Node v18 and `yarn` (or `pnpm`)
- Install [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Create a personal access token (classic)](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token) in github with the following permissions: `codespace, project, repo, workflow, write:packages`
- Create global `.yarnrc.yml` file: `touch ~/.yarnrc.yml` and paste the following:
  ```
  npmRegistries:
    https://npm.pkg.github.com/:
      npmAuthToken: <Your GitHub Personal Access Token>
  ```
- Run `yarn` to install dependencies
- Run `forge install` to install other dependencies

## Testing

Run: `forge test`. E.g.

- `forge test -vvv --no-match-test "SlowFuzz"` will run all of the tests except some exceptionally slow fuzzing tests.
- `forge test -vvv"` will run all of the tests
