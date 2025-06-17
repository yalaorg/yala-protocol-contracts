import '@nomicfoundation/hardhat-ethers'
import 'hardhat-deploy'
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers'
import {
	YalaCore,
	DebtToken,
	Factory,
	BorrowerOperations,
	MockPriceFeed,
	MockCollateralToken,
	PSM,
	MultiTroveGetters,
	MockAggregatorV3Interface,
	PriceFeed,
	StabilityPool,
} from '../types'
import { ethers } from 'hardhat'
import { Contract, encodeRlp, keccak256, parseEther, parseUnits, ZeroAddress } from 'ethers'
import { updateMockAggregatorV3Price } from './utils'

export interface IFixture {
	signer: HardhatEthersSigner
	signers: HardhatEthersSigner[]
	gasPool: Contract
	YalaCore: YalaCore
	DebtToken: DebtToken
	Factory: Factory
	BorrowerOperations: BorrowerOperations
	PriceFeed: PriceFeed
	MockAggregatorV3Interface: MockAggregatorV3Interface
	MockCollateralToken: MockCollateralToken
	MockPriceFeed: MockPriceFeed,
	StabilityPool: StabilityPool
	PSM: PSM
	MultiTroveGetters: MultiTroveGetters
	account: string
	accounts: string[]
}

export interface ICRSMFixture {
	NullCRSMNFTMetadata: NullCRSMNFTMetadata
	CRSM: CRSM
	CRSMFactory: CRSMFactory
}

async function computeAddress(account: string, nonce?: number): Promise<string> {
	if (!nonce) {
		nonce = await ethers.provider.getTransactionCount(account)
	}
	let nonceHex = BigInt(nonce!).toString(16)
	if (nonceHex.length % 2 != 0) {
		nonceHex = '0' + nonceHex
	}
	return '0x' + keccak256(encodeRlp([account, '0x' + nonceHex])).substring(26)
}

export async function loadFixture(): Promise<IFixture> {
	const gasCompensation = parseEther('200')
	const minNetDebt = parseEther('2000')
	const maxCollGasCompensation = parseEther('0.1')
	const signers = await ethers.getSigners()
	const signer = signers[0]
	const account = signer.address
	const accounts = signers.map(s => s.address)
	const gasPool = await ethers.deployContract('GasPool', signer)
	const MockLayerZeroEndpoint = await ethers.deployContract('MockLayerZeroEndpoint', signer)
	const MockCollateralToken = await ethers.deployContract('MockCollateralToken', signer)
	const MockPriceFeed = await ethers.deployContract('MockPriceFeed', signer)
	const nonce = await signer.getNonce()
	const yalaCoreAddress = await computeAddress(account, nonce)
	const debtTokenAddress = await computeAddress(account, nonce + 1)
	const stablityPoolAddress = await computeAddress(account, nonce + 2)
	const borrowerOperationsAddress = await computeAddress(account, nonce + 3)
	// eslint-disable-next-line @typescript-eslint/no-unused-vars
	const troveManagerImplAddress = computeAddress(account, nonce + 4)
	const psmImplAddress = await computeAddress(account, nonce + 5)
	const factoryAddress = await computeAddress(account, nonce + 6)
	const YalaCore = await ethers.deployContract('YalaCore', [accounts[0], accounts[1], accounts[2]], signer)
	const DebtToken = await ethers.deployContract('DebtToken', [
		'Yala Stable Coin',
		'YU',
		stablityPoolAddress,
		borrowerOperationsAddress,
		MockLayerZeroEndpoint.target,
		accounts[0],
		factoryAddress,
		gasPool.target,
		gasCompensation
	])
	const StabilityPool = await ethers.deployContract('StabilityPool', [yalaCoreAddress, factoryAddress, debtTokenAddress], signer)
	const BorrowerOperations = await ethers.deployContract('BorrowerOperations', [yalaCoreAddress, debtTokenAddress, factoryAddress, minNetDebt, gasCompensation], signer)
	const TroveManagerImpl = await ethers.deployContract('TroveManager', [
		yalaCoreAddress,
		factoryAddress,
		gasPool.target,
		debtTokenAddress,
		borrowerOperationsAddress,
		stablityPoolAddress,
		gasCompensation,
		maxCollGasCompensation], signer)
	const PSM = await ethers.deployContract('PSM', [yalaCoreAddress, factoryAddress, debtTokenAddress], signer)
	const Factory = await ethers.deployContract('Factory',
		[
			yalaCoreAddress,
			debtTokenAddress,
			stablityPoolAddress,
			borrowerOperationsAddress,
			TroveManagerImpl.target,
			PSM.target
		], signer)
	const MockAggregatorV3Interface = await ethers.deployContract('MockAggregatorV3Interface', [account], signer)
	const tokenPrice = parseUnits('100000', 8)
	await updateMockAggregatorV3Price(MockAggregatorV3Interface, 99, tokenPrice)
	const PriceFeed = await ethers.deployContract('PriceFeed', [yalaCoreAddress, [[MockCollateralToken.target, MockAggregatorV3Interface.target, 3600]]], signer)
	const MultiTroveGetters = await ethers.deployContract('MultiTroveGetters', [borrowerOperationsAddress], signer)
	return {
		signers,
		signer,
		MultiTroveGetters,
		gasPool,
		MockCollateralToken,
		MockPriceFeed,
		PriceFeed,
		PSM,
		MockAggregatorV3Interface,
		StabilityPool,
		YalaCore,
		DebtToken,
		Factory,
		BorrowerOperations,
		account,
		accounts,
	}
}

export async function loadCRSMFixture(fixture: IFixture): Promise<ICRSMFixture> {
	const { account, signer, YalaCore, BorrowerOperations, StabilityPool, DebtToken } = fixture
	const NullCRSMNFTMetadata = await ethers.deployContract('NullCRSMNFTMetadata', signer)
	const nonce = await signer.getNonce()
	const crsmAddress = await computeAddress(account, nonce)
	const crsmFactoryAddress = await computeAddress(account, nonce + 1)
	const CRSM = await ethers.deployContract('CRSM', [crsmFactoryAddress, BorrowerOperations.target, StabilityPool.target, DebtToken.target], signer)
	const CRSMFactory = await ethers.deployContract('CRSMFactory', [YalaCore.target, BorrowerOperations.target, DebtToken.target, crsmAddress, NullCRSMNFTMetadata.target], signer)
	return {
		NullCRSMNFTMetadata,
		CRSM,
		CRSMFactory
	}
}
