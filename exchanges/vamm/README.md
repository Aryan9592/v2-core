# Voltz V2 - VAMM

This package contains the smart contracts for the Voltz V2 VAMM. It is an exchange layer powered by a concentrated liquidity virtual AMM used for price discovery.

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

Run: `forge test`

## Deployment

This project uses Cannon for deployments. For more details, go [here](https://github.com/usecannon/cannon).

## License

The license for Voltz V2 VAMM is detailed in [`LICENSE`](./LICENSE).
