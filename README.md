![License: GPL](https://img.shields.io/badge/license-GPLv3-blue)![Version Badge](https://img.shields.io/badge/version-0.0.1-lightgrey.svg)
# Yala Protocol

Yala protocol contracts

## Install

`npm i -f`

## Get start

1. create `.env` file  and set your mnemonic as below

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
