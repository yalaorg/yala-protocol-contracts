import '@nomicfoundation/hardhat-chai-matchers'
import '@nomicfoundation/hardhat-ethers'
import '@nomicfoundation/hardhat-verify'
import '@typechain/hardhat'

import 'hardhat-deploy'
import 'hardhat-gas-reporter'
import 'solidity-coverage'
import 'hardhat-storage-layout'
import 'solidity-docgen'

import { config as dotenvConfig } from 'dotenv'
import { resolve } from 'path'

const dotenvConfigPath: string = process.env.DOTENV_CONFIG_PATH || './.env'
dotenvConfig({ path: resolve(__dirname, dotenvConfigPath) })

if (process.env.NODE_ENV === 'dev' || process.env.NODE_ENV === 'production') {
	require('./tasks')
}

const accounts = {
	mnemonic: process.env.MNEMONIC || 'test test test test test test test test test test test test',
}

const config = {
	solidity: {
		overrides: {},
		compilers: [
			{
				version: '0.8.28',
				settings: {
					optimizer: { enabled: true, runs: 100 },
				},
			}
		],
	},
	namedAccounts: {
		deployer: 0,
		simpleERC20Beneficiary: 1
	},
	networks: {
		sepolia: {
			url: process.env.SEPOLIA ?? '',
			accounts,
			gas: 'auto',
			gasPrice: 'auto',
			gasMultiplier: 1.3,
			timeout: 100000
		},
		'monad-testnet': {
			url: process.env.MONAD_TESTNET_RPC ?? '',
			accounts,
			gas: 'auto',
			gasPrice: 'auto',
			gasMultiplier: 1.3,
			timeout: 100000
		},
		mainnet: {
			url: process.env.MAINNET ?? '',
			accounts,
			gas: 'auto',
			gasPrice: 'auto',
			gasMultiplier: 1.3,
			timeout: 100000
		},
		localhost: {
			url: 'http://127.0.0.1:8545',
			accounts,
			gas: 'auto',
			gasPrice: 'auto',
			gasMultiplier: 1.5,
			timeout: 100000
		},
		hardhat: {
			// forking: {
			// 	enabled: true,
			// 	url: process.env.MAINNET,
			// 	blockNumber: Number(process.env.FORK_BLOCK),
			// },
			accounts,
			gas: 'auto',
			gasPrice: 'auto',
			gasMultiplier: 2,
			chainId: 1337,
			mining: {
				auto: true,
				interval: 5000
			}
		}
	},
	etherscan: {
		apiKey: {
			mainnet: process.env.APIKEY_MAINNET!,
			sepolia: process.env.APIKEY_SEPOLIA!
		}
	},
	paths: {
		deploy: 'deploy',
		artifacts: 'artifacts',
		cache: 'cache',
		sources: 'contracts',
		tests: 'test'
	},
	gasReporter: {
		currency: 'USD',
		gasPrice: 100,
		enabled: process.env.REPORT_GAS ? true : false,
		coinmarketcap: process.env.COINMARKETCAP_API_KEY,
		maxMethodDiff: 10,
	},
	docgen: {
		templates: './docs/templates',
		exclude: ['dependencies', 'test'],
		root: './',
		sourcesDir: './contracts',
		pages: 'files',
		outputDir: './docs/output'
	},
	typechain: {
		outDir: 'types',
		target: 'ethers-v6',
	},
	mocha: {
		timeout: 0,
	}
}

export default config
