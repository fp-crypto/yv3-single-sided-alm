# Yearn V3 Single-Sided Automated Liquidity Management Strategy

This is a Yearn V3 Tokenized Strategy implementation for single-sided Automated Liquidity Management (ALM) using Steer Protocol. The strategy manages liquidity positions in Uniswap V3 pools through Steer's multi-position liquidity manager.

## Strategy Overview

The strategy operates by:

1. Taking single-sided deposits in the strategy's asset token
2. Swapping a portion of assets to achieve balanced LP deposits based on current pool composition
3. Depositing balanced amounts into Steer's multi-position liquidity manager
4. Managing withdrawals by unwinding LP positions and swapping back to the asset token
5. Automatically rebalancing positions based on configurable parameters

### Key Features

- **Single-sided deposits**: Users can deposit only the strategy's primary asset
- **Automatic rebalancing**: Maintains optimal LP composition through intelligent swapping
- **Target idle management**: Configurable percentage of assets to keep idle for gas efficiency
- **Dust threshold protection**: `minAsset` parameter prevents uneconomical small operations
- **Swap value limits**: `maxSwapValue` parameter controls maximum swap sizes per transaction
- **Tend trigger system**: Gas-aware and time-based triggers for maintenance operations
- **Auction integration**: Optional auction mechanism for reward token liquidation
- **Merkl rewards**: Built-in support for claiming Merkl distributor rewards

For a more complete overview of how the Tokenized Strategies work please visit the [TokenizedStrategy Repo](https://github.com/yearn/tokenized-strategy).

## Architecture

### Core Components

- **Strategy.sol**: Main strategy contract inheriting from `BaseHealthCheck` and implementing `IUniswapV3SwapCallback`

  - Manages deposits/withdrawals to/from Steer LP positions
  - Handles token swaps via Uniswap V3 pools to maintain balanced liquidity
  - Calculates asset valuations across LP positions and loose token balances

- **StrategyFactory.sol**: Factory contract for deploying new strategy instances

- **IStrategyInterface.sol**: Testing interface that extends the base `IStrategy` with strategy-specific functions

### Dependencies

- **Tokenized Strategy Framework**: Base strategy implementation from Yearn V3
- **Steer Protocol**: Multi-position liquidity management via `ISushiMultiPositionLiquidityManager`
- **Uniswap V3**: Direct pool interactions for token swaps with callback implementation
- **OpenZeppelin**: Standard utilities and SafeERC20

### Key Strategy Parameters

- `targetIdleAssetBps`: Percentage of assets to keep idle (0-10000 basis points)
- `targetIdleBufferBps`: Buffer around target idle for tend triggers (default 1000 = 10%)
- `minAsset`: Minimum asset amount for any operation (dust threshold)
- `maxSwapValue`: Maximum value that can be swapped in a single transaction
- `minTendWait`: Minimum time between tend operations (default 5 minutes)
- `maxTendBaseFeeGwei`: Maximum acceptable base fee for tend operations (default 100 gwei)
- `pairedTokenDiscountBps`: Additional discount for paired token valuations (default 50 = 0.5%)

## How to start

### Requirements

- First you will need to install [Foundry](https://book.getfoundry.sh/getting-started/installation).
  NOTE: If you are on a windows machine it is recommended to use [WSL](https://learn.microsoft.com/en-us/windows/wsl/install)
- Install [Node.js](https://nodejs.org/en/download/package-manager/)

### Clone this repository

```sh
git clone --recursive https://github.com/yearn/tokenized-strategy-foundry-mix

cd tokenized-strategy-foundry-mix

yarn
```

### Set your environment Variables

Use the `.env.example` template to create a `.env` file and store the environement variables. You will need to populate the `RPC_URL` for the desired network(s). RPC url can be obtained from various providers, including [Ankr](https://www.ankr.com/rpc/) (no sign-up required) and [Infura](https://infura.io/).

Use .env file

1. Make a copy of `.env.example`
2. Add the value for `ETH_RPC_URL` and other example vars
   NOTE: If you set up a global environment variable, that will take precedence.

### Build the project

```sh
make build
```

Run tests

```sh
make test
```

## Strategy Implementation

This repository contains a complete implementation of a Single-Sided ALM strategy. The strategy overrides the following functions from BaseHealthCheck:

- `_deployFunds`: No-op (deployment happens via `_tend`)
- `_freeFunds`: No-op (will never be triggered)
- `_harvestAndReport`: Returns estimated total assets
- `_tend`: Core rebalancing logic with target idle management
- `_tendTrigger`: Gas and time-aware trigger logic
- `_emergencyWithdraw`: Withdraws from LP positions
- `availableDepositLimit`: Respects strategy deposit limits
- `availableWithdrawLimit`: Returns idle asset balance

### Custom Functions

The strategy also implements several management functions:

- `setTargetIdleAssetBps`: Configure idle asset percentage
- `setMinAsset`: Set dust threshold
- `setMaxSwapValue`: Limit swap sizes
- `setMinTendWait`: Configure tend frequency
- `setMaxTendBaseFee`: Set gas price limits
- `manualSwapPairedTokenToAsset`: Emergency manual swapping
- `manualWithdrawFromLp`: Emergency manual LP withdrawal

For a complete guide to creating Tokenized Strategies please visit: https://docs.yearn.fi/developers/v3/strategy_writing_guide

NOTE: Compiler defaults to 8.23 with Cancun EVM version and can be adjusted in the foundry.toml.

## Testing

The strategy includes comprehensive tests covering all functionality:

- **Operation.t.sol**: Core strategy operations, deposits, withdrawals, and tends
- **ManagementTests.t.sol**: Parameter management and access control
- **TendTriggerTests.t.sol**: Tend trigger logic and timing
- **MaxSwapValueTests.t.sol**: Swap value limiting functionality
- **ErrorAndBoundaryTests.t.sol**: Edge cases, error conditions, and boundary testing
- **CallbackTests.t.sol**: Uniswap V3 swap callback validation
- **AuctionTests.t.sol**: Auction integration testing

Due to the nature of the BaseStrategy utilizing an external contract for the majority of its logic, the tests utilize the pre-built [IStrategyInterface](./src/interfaces/IStrategyInterface.sol) to cast deployed strategies for testing, as seen in the Setup example.

Example:

```solidity
Strategy _strategy = new Strategy(asset, name, steerLP);
IStrategyInterface strategy = IStrategyInterface(address(_strategy));
```

Tests run in a fork environment using real Steer LP contracts on Polygon. The testing framework requires a forked environment with RPC URLs configured in `.env` file to interact with actual Steer LP and Uniswap V3 pools.

### Test Configuration

The strategy is tested against multiple real Steer LP pairs including:

- DAI/USDC 0.05% fee pools
- USDC/USDT 0.01% fee pools
- Various other stable and volatile pairs

Tests must use `IStrategyInterface` to properly test all functions since BaseStrategy uses external contracts for core logic.

```sh
make test
```

Run tests with traces (very useful)

```sh
make trace
```

Run specific test contract:

```sh
make test-contract contract=OperationTest
make test-contract contract=ManagementTests
make test-contract contract=TendTriggerTests
make test-contract contract=MaxSwapValueTests
```

Run specific test contract with traces:

```sh
make trace-contract contract=OperationTest
make trace-contract contract=ErrorAndBoundaryTests
```

Run specific test function:

```sh
make test-test test=test_operation
make test-test test=test_tendTrigger
```

See here for some tips on testing [`Testing Tips`](https://book.getfoundry.sh/forge/tests.html)

This strategy is designed for **Polygon** and requires a Polygon RPC URL. The default fork configuration is set for Polygon in the Makefile. When testing, make sure you have a valid `FORK_URL` for Polygon set in your `.env` file:

```bash
FORK_URL=https://polygon.gateway.tenderly.co/YOUR_KEY
# or
FORK_URL=https://polygon-mainnet.infura.io/v3/YOUR_KEY
```

The strategy integrates with Polygon-specific contracts:

- Merkl Distributor: `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`
- Various Steer LP managers deployed on Polygon
- Uniswap V3 pools on Polygon

To update to a new API version of the TokenizeStrategy you will need to simply remove and reinstall the dependency.

### Test Coverage

Run the following command to generate a test coverage:

```sh
make coverage
```

To generate test coverage report in HTML, you need to have installed [`lcov`](https://github.com/linux-test-project/lcov) and run:

```sh
make coverage-html
```

The generated report will be in `coverage-report/index.html`.

### Deployment

#### Contract Verification

Once the Strategy is fully deployed and verified, you will need to verify the TokenizedStrategy functions. To do this, navigate to the /#code page on Etherscan.

1. Click on the `More Options` drop-down menu
2. Click "is this a proxy?"
3. Click the "Verify" button
4. Click "Save"

This should add all of the external `TokenizedStrategy` functions to the contract interface on Etherscan.

## CI

This repo uses [GitHub Actions](.github/workflows) for CI. There are three workflows: lint, test and slither for static analysis.

To enable test workflow you need to add the `ETH_RPC_URL` secret to your repo. For more info see [GitHub Actions docs](https://docs.github.com/en/codespaces/managing-codespaces-for-your-organization/managing-encrypted-secrets-for-your-repository-and-organization-for-github-codespaces#adding-secrets-for-a-repository).

If the slither finds some issues that you want to suppress, before the issue add comment: `//slither-disable-next-line DETECTOR_NAME`. For more info about detectors see [Slither docs](https://github.com/crytic/slither/wiki/Detector-Documentation).

### Coverage

If you want to use [`coverage.yml`](.github/workflows/coverage.yml) workflow on other chains than mainnet, you need to add the additional `CHAIN_RPC_URL` secret.

Coverage workflow will generate coverage summary and attach it to PR as a comment. To enable this feature you need to add the [`GH_TOKEN`](.github/workflows/coverage.yml#L53) secret to your Github repo. Token must have permission to "Read and Write access to pull requests". To generate token go to [Github settings page](https://github.com/settings/tokens?type=beta). For more info see [GitHub Access Tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).
