import { Addressable, MaxUint256, parseEther, Signer, ZeroAddress } from 'ethers'
import { ICRSMFixture, IFixture } from './fixture'
import { TroveManager__factory, TroveManager, MockAggregatorV3Interface, PSM__factory, CRSM__factory } from '../types'
import { ethers } from 'hardhat'

export async function deployNewCDP(
	fixture: IFixture,
	params?: {
		interestRate?: bigint,
		maxDebt?: bigint,
		spYieldPCT?: bigint,
		maxCollGasCompensation?: bigint,
		liquidationPenaltySP?: bigint,
		liquidationPenaltyRedistribution?: bigint,
		MCR?: bigint,
		SCR?: bigint,
		CCR?: bigint,
		metadataNFT?: string | Addressable,
	},
	opts?: {
		collateralToken?: string | Addressable
	}
) {
	const { Factory, MockCollateralToken, MockPriceFeed, signer } = fixture
	params = {
		interestRate: parseEther('0.1'),
		maxDebt: parseEther('20000000000'),
		spYieldPCT: parseEther('0.8'),
		maxCollGasCompensation: parseEther('0.1'),
		liquidationPenaltySP: parseEther('0.05'),
		liquidationPenaltyRedistribution: parseEther('0.05'),
		MCR: parseEther('1.1'),
		SCR: parseEther('1.3'),
		CCR: parseEther('1.5'),
		metadataNFT: ZeroAddress,
		...params
	}
	opts = {
		collateralToken: MockCollateralToken.target as string,
		...opts
	}
	const salt = '0x' + Buffer.alloc(32, '0').toString('hex')
	const troveManagerAddress = await Factory.deployNewCDP.staticCall(opts.collateralToken!, salt, MockPriceFeed.target, ZeroAddress, params as any)
	await Factory.deployNewCDP(opts.collateralToken!, salt, MockPriceFeed.target, ZeroAddress, params as any)
	return TroveManager__factory.connect(troveManagerAddress, signer)
}

export async function deployNewPSM(
	fixture: IFixture,
	opts?: {
		pegToken?: string | Addressable,
		feeIn?: bigint,
		feeOut?: bigint,
		supplyCap?: bigint
	}
) {
	const { Factory, signer } = fixture
	const newPegToken = await ethers.deployContract('MockCollateralToken', signer)
	opts = {
		pegToken: newPegToken.target,
		feeIn: parseEther('0.01'),
		feeOut: parseEther('0.02'),
		supplyCap: parseEther('10000000'),
		...opts
	}
	const psmAddress = await Factory.deployNewPSM.staticCall(ZeroAddress, opts!.pegToken!, opts.feeIn!, opts.feeOut!, opts.supplyCap!)
	await Factory.deployNewPSM(ZeroAddress, opts!.pegToken!, opts.feeIn!, opts.feeOut!, opts.supplyCap!)
	return { psm: PSM__factory.connect(psmAddress, signer), pegToken: newPegToken }
}

export async function openTrove(
	fixture: IFixture,
	params?: {
		coll?: bigint,
		debt?: bigint,
		price?: bigint,
		troveManager?: TroveManager,
		signer?: Signer,
	},
) {
	const { BorrowerOperations, MockCollateralToken, MockPriceFeed, signer } = fixture
	params = {
		coll: parseEther('1'),
		debt: parseEther('1800'),
		price: parseEther('100000'),
		signer,
		...params
	}

	params.troveManager = params.troveManager ?? await deployNewCDP(fixture)
	const token = await params.troveManager.collateralToken()
	await (MockCollateralToken.attach(token) as any).connect(signer).transfer(await params.signer!.getAddress(), params.coll)
	await (MockCollateralToken.attach(token) as any).connect(params.signer!).approve(BorrowerOperations.target, MaxUint256)
	await MockPriceFeed.connect(params.signer).updatePrice(token, params.price!)
	const id = await BorrowerOperations.connect(params.signer).openTrove.staticCall(params.troveManager.target, await params.signer!.getAddress(), params.coll!, params.debt!)
	await BorrowerOperations.connect(params.signer).openTrove(params.troveManager.target, await params.signer!.getAddress(), params.coll!, params.debt!)
	return { troveManager: params.troveManager, id }
}


export async function updateMockAggregatorV3Price(
	aggregatorV3Interface: MockAggregatorV3Interface, roundId: number, price: bigint) {
	const updateTime = (await ethers.provider.getBlock('latest'))!.timestamp
	await aggregatorV3Interface.updateRoundData({
		roundId,
		answer: price,
		startedAt: updateTime,
		updatedAt: updateTime,
		answeredInRound: price
	})
}

export async function createNewCRSM(fixture: IFixture, crsmFixture: ICRSMFixture,
	params?: {
		TRGCR?: bigint,
		TARCR?: bigint,
		MAX_TARCR?: bigint,
		debtGas?: bigint
		amount?: bigint,
		troveParams?: {
			coll?: bigint,
			debt?: bigint,
			price?: bigint,
			troveManager?: TroveManager,
			signer?: Signer,
		}
	}) {
	const { troveManager, id } = await openTrove(fixture, params?.troveParams)
	const { CRSMFactory } = crsmFixture
	const { DebtToken, signer } = fixture
	params = {
		TRGCR: parseEther('1.2'),
		TARCR: parseEther('1.4'),
		MAX_TARCR: parseEther('1.5'),
		debtGas: 0n,
		amount: parseEther('200'),
		...params
	}
	await DebtToken.approve(CRSMFactory.target, MaxUint256)
	const crsmAddress = await CRSMFactory.createNewCRSM.staticCall(troveManager.target, id, params.TRGCR!, params.TARCR!, params.MAX_TARCR!, params.debtGas!, params.amount!)
	await CRSMFactory.createNewCRSM(troveManager.target, id, params.TRGCR!, params.TARCR!, params.MAX_TARCR!, params.debtGas!, params.amount!)
	return { crsm: CRSM__factory.connect(crsmAddress, signer), troveManager, id }
}