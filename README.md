![License: GPL](https://img.shields.io/badge/license-GPLv3-blue)![Version Badge](https://img.shields.io/badge/version-0.0.1-lightgrey.svg)

# Bitcoin liquidity layer protocol contracts 

Yala is a Bitcoin-native liquidity protocol that enables Bitcoin holders to earn real yield from DeFi and RWAs without giving up ownership of their assets. The repository contains protocol smart contracts with LayerZero cross-chain infrastructure and Chainlink oracle integration.
Core mechanisms include collateral management, stablity pool and PSM, establishing a liquidity infrastructure layer for the Bitcoin ecosystem.

## Install

`npm i -f`

## Get start

1. create `.env` file  and set your environment variables as below

   ```
   MNEMONIC="yourn mnemonic"
   MAINNET="mainnet rpc"
   SEPOLIA="seplolia rpc"
   APIKEY_MAINNET="etherscan mainnet api key"
   APIKEY_SEPOLIA="etherscan sepoliad api key"
   OWENR="protocol admin address" ## required on local development
   GUARDIAN="protocol guardian address" ## required on local development
   FEE_RECEIVER="protocol fee receiver address" ## required on local development
   LAYER_ZERO_ENDPOINT="layer zero endpoint"
   LAYER_ZERO_DELEGATE="layer zero delegate" ## required on local development
   COLLATERAL_TOEKN="collateral token address"
   CHAINLINK_AGGREGATORV3="chainlink aggregator v3 address"
   ```

2. compile contracts, it will generate contract artifacts also typechains

   `yarn build`

3. test contracts

   `yarn test`

---

Once the rpc url is unavailable, check it [here](https://chainlist.org/)
