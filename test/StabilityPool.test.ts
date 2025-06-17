import '@nomicfoundation/hardhat-ethers'
import { loadFixture, IFixture } from './fixture'
import { formatEther, formatUnits, parseEther, parseUnits, Signer } from 'ethers'
import { deployNewCDP, openTrove } from './utils'
import { ethers } from 'hardhat'
import { TroveManager } from '../types'
import { time } from '@nomicfoundation/hardhat-network-helpers'

describe('Test StabilityPool', () => {
	let fixture: IFixture

	beforeEach(async () => {
		fixture = await loadFixture()
	})
	async function createMultipleTroves(troveManager: TroveManager, debt: bigint, coll: bigint, price: bigint, signer: Signer, amount: number) {
		const troveIds = []
		for (let i = 0; i < amount; i++) {
			const { id } = await openTrove(fixture, { debt, coll, signer, price, troveManager })
			troveIds.push(id)
		}
		return troveIds
	}

	it('get yield gains', async () => {
		const { StabilityPool, MockPriceFeed, MultiTroveGetters, DebtToken, signer, signers, accounts } = fixture
		const CollateralToken0 = await ethers.deployContract('MockDecimalCollateralToken', [18], signer)
		const CollateralToken1 = await ethers.deployContract('MockDecimalCollateralToken', [8], signer)

		const troveManager0 = await deployNewCDP(fixture, undefined, { collateralToken: CollateralToken0.target })
		const troveManager1 = await deployNewCDP(fixture, undefined, { collateralToken: CollateralToken1.target })
		const id00s = await createMultipleTroves(troveManager0, parseEther('5000'), parseEther('1'), parseEther('100000'), signers[0], 100)
		const id01s = await createMultipleTroves(troveManager0, parseEther('5000'), parseEther('1'), parseEther('100000'), signers[1], 100)
		const id10s = await createMultipleTroves(troveManager1, parseEther('50000'), parseUnits('1', 8), parseUnits('100000', 28), signers[0], 100)
		const id11s = await createMultipleTroves(troveManager1, parseEther('50000'), parseUnits('1', 8), parseUnits('100000', 28), signers[1], 100)
		await StabilityPool.connect(signers[0]).provideToSP(parseEther('1000000'))
		await StabilityPool.connect(signers[1]).provideToSP(parseEther('500000'))

		const oneYear = 365 * 24 * 3600
		await time.increase(oneYear)
		await MockPriceFeed.updatePrice(CollateralToken1.target, parseUnits('50000', 28))
		const allTroves1 = await MultiTroveGetters.getTroves.staticCall(troveManager1.target, 0, 400)
		const liquidationIds1 = []
		for (const trove of allTroves1.states) {
			if (trove.ICR < parseEther('1.1')) {
				liquidationIds1.push(trove.id)
			}
		}
		{
			const getYieldGains0 = await StabilityPool.getYieldGains(accounts[0])
			// console.log('getYieldGains0', formatEther(getYieldGains0))
			const getYieldGains1 = await StabilityPool.getYieldGains(accounts[1])
			// console.log('getYieldGains1', formatEther(getYieldGains1))
		}
		{
			await troveManager1.batchLiquidate(liquidationIds1.slice(0, 20))
			await time.increase(oneYear)
			const getYieldGains0 = await StabilityPool.getYieldGains(accounts[0])
			// console.log('getYieldGains0', formatEther(getYieldGains0))
			const getYieldGains1 = await StabilityPool.getYieldGains(accounts[1])
			// console.log('getYieldGains1', formatEther(getYieldGains1))
		}
		{
			await StabilityPool.connect(signers[0]).claimYield(accounts[10])
			// console.log('claimYield0', formatEther(await DebtToken.balanceOf(accounts[10])))
			await StabilityPool.connect(signers[1]).claimYield(accounts[11])
			// console.log('claimYield1', formatEther(await DebtToken.balanceOf(accounts[11])))
			await time.increase(oneYear)
		}
		{
			// console.log('accounts0', formatEther(await DebtToken.balanceOf(accounts[0])))
			const deposit0 = await StabilityPool.getCompoundedDebtDeposit(accounts[0])
			// console.log('deposit0', formatEther(deposit0))
			await StabilityPool.connect(signers[0]).withdrawFromSP(deposit0)
			// console.log('accounts0', formatEther(await DebtToken.balanceOf(accounts[0])))

			// console.log('accounts1', formatEther(await DebtToken.balanceOf(accounts[1])))
			const deposit1 = await StabilityPool.getCompoundedDebtDeposit(accounts[1])
			// console.log('deposit1', formatEther(deposit1))
			await StabilityPool.connect(signers[1]).withdrawFromSP(deposit1)
			// console.log('accounts1', formatEther(await DebtToken.balanceOf(accounts[1])))
			await StabilityPool.connect(signers[0]).claimYield(accounts[10])
			// console.log('claimYield0', formatEther(await DebtToken.balanceOf(accounts[10])))
			await StabilityPool.connect(signers[1]).claimYield(accounts[11])
			// console.log('claimYield1', formatEther(await DebtToken.balanceOf(accounts[11])))
			// console.log('StabilityPool', formatEther(await DebtToken.balanceOf(StabilityPool.target)))

		}
	})

	it('provide and withdraw', async () => {
		const { StabilityPool, MockPriceFeed, MultiTroveGetters, DebtToken, signer, signers, accounts } = fixture
		const CollateralToken0 = await ethers.deployContract('MockDecimalCollateralToken', [18], signer)
		const CollateralToken1 = await ethers.deployContract('MockDecimalCollateralToken', [8], signer)
		const CollateralToken2 = await ethers.deployContract('MockDecimalCollateralToken', [9], signer)

		const troveManager0 = await deployNewCDP(fixture, undefined, { collateralToken: CollateralToken0.target })
		const troveManager1 = await deployNewCDP(fixture, undefined, { collateralToken: CollateralToken1.target })
		const troveManager2 = await deployNewCDP(fixture, undefined, { collateralToken: CollateralToken2.target })
		const id00s = await createMultipleTroves(troveManager0, parseEther('5000'), parseEther('1'), parseEther('100000'), signers[0], 50)
		const id01s = await createMultipleTroves(troveManager0, parseEther('80000'), parseEther('1'), parseEther('100000'), signers[1], 50)
		const id02s = await createMultipleTroves(troveManager0, parseEther('50000'), parseEther('1'), parseEther('100000'), signers[2], 50)
		const id03s = await createMultipleTroves(troveManager0, parseEther('15000'), parseEther('2'), parseEther('100000'), signers[3], 50)
		const id10s = await createMultipleTroves(troveManager1, parseEther('5000'), parseUnits('1', 8), parseUnits('100000', 28), signers[0], 50)
		const id11s = await createMultipleTroves(troveManager1, parseEther('60000'), parseUnits('1', 8), parseUnits('100000', 28), signers[1], 50)
		const id12s = await createMultipleTroves(troveManager1, parseEther('50000'), parseUnits('1', 8), parseUnits('100000', 28), signers[2], 50)
		const id13s = await createMultipleTroves(troveManager1, parseEther('8000'), parseUnits('2', 8), parseUnits('100000', 28), signers[3], 50)
		const id20s = await createMultipleTroves(troveManager2, parseEther('50000'), parseUnits('1', 9), parseUnits('100000', 27), signers[0], 50)
		const id21s = await createMultipleTroves(troveManager2, parseEther('80000'), parseUnits('1', 9), parseUnits('100000', 27), signers[1], 50)
		const id22s = await createMultipleTroves(troveManager2, parseEther('10000'), parseUnits('1', 9), parseUnits('100000', 27), signers[2], 50)
		const id23s = await createMultipleTroves(troveManager2, parseEther('150000'), parseUnits('2', 9), parseUnits('100000', 27), signers[3], 50)
		await StabilityPool.connect(signers[0]).provideToSP(parseEther('1000000'))
		await StabilityPool.connect(signers[1]).provideToSP(parseEther('2000000'))
		await StabilityPool.connect(signers[2]).provideToSP(parseEther('3000000'))
		await StabilityPool.connect(signers[3]).provideToSP(parseEther('4000000'))

		await MockPriceFeed.updatePrice(CollateralToken0.target, parseEther('88000'))
		await MockPriceFeed.updatePrice(CollateralToken1.target, parseUnits('65000', 28))
		await MockPriceFeed.updatePrice(CollateralToken2.target, parseUnits('85000', 27))
		const allTroves0 = await MultiTroveGetters.getTroves.staticCall(troveManager0.target, 0, 400)
		const allTroves1 = await MultiTroveGetters.getTroves.staticCall(troveManager1.target, 0, 400)
		const allTroves2 = await MultiTroveGetters.getTroves.staticCall(troveManager2.target, 0, 400)
		const liquidationIds0 = []
		for (const trove of allTroves0.states) {
			if (trove.ICR < parseEther('1.1')) {
				liquidationIds0.push(trove.id)
			}
		}
		const liquidationIds1 = []
		for (const trove of allTroves1.states) {
			if (trove.ICR < parseEther('1.1')) {
				liquidationIds1.push(trove.id)
			}
		}
		const liquidationIds2 = []
		for (const trove of allTroves2.states) {
			if (trove.ICR < parseEther('1.1')) {
				liquidationIds2.push(trove.id)
			}
		}

		{
			await troveManager0.batchLiquidate(liquidationIds0.slice(0, 20))
			const getCompoundedDebtDeposit0 = await StabilityPool.getCompoundedDebtDeposit(accounts[0])
			// console.log('getCompoundedDebtDeposit0', getCompoundedDebtDeposit0, formatEther(getCompoundedDebtDeposit0))
			const getCompoundedDebtDeposit1 = await StabilityPool.getCompoundedDebtDeposit(accounts[1])
			// console.log('getCompoundedDebtDeposit1', getCompoundedDebtDeposit1, formatEther(getCompoundedDebtDeposit1))
			const getCompoundedDebtDeposit2 = await StabilityPool.getCompoundedDebtDeposit(accounts[2])
			// console.log('getCompoundedDebtDeposit2', getCompoundedDebtDeposit2, formatEther(getCompoundedDebtDeposit2))
			const getCompoundedDebtDeposit3 = await StabilityPool.getCompoundedDebtDeposit(accounts[3])
			// console.log('getCompoundedDebtDeposit3', getCompoundedDebtDeposit3, formatEther(getCompoundedDebtDeposit3))
			const getDepositorCollateralGain0 = await StabilityPool.getDepositorCollateralGain(accounts[0])
			// console.log('getDepositorCollateralGain0', getDepositorCollateralGain0)
			const getDepositorCollateralGain1 = await StabilityPool.getDepositorCollateralGain(accounts[1])
			// console.log('getDepositorCollateralGain1', getDepositorCollateralGain1)
			const getDepositorCollateralGain2 = await StabilityPool.getDepositorCollateralGain(accounts[2])
			// console.log('getDepositorCollateralGain2', getDepositorCollateralGain2)
			const getDepositorCollateralGain3 = await StabilityPool.getDepositorCollateralGain(accounts[3])
			// console.log('getDepositorCollateralGain3', getDepositorCollateralGain3)
			await time.increase(365 * 24 * 3600)
		}
		{
			await troveManager1.batchLiquidate(liquidationIds1.slice(0, 20))
			const getCompoundedDebtDeposit0 = await StabilityPool.getCompoundedDebtDeposit(accounts[0])
			// console.log('getCompoundedDebtDeposit0', getCompoundedDebtDeposit0, formatEther(getCompoundedDebtDeposit0))
			const getCompoundedDebtDeposit1 = await StabilityPool.getCompoundedDebtDeposit(accounts[1])
			// console.log('getCompoundedDebtDeposit1', getCompoundedDebtDeposit1, formatEther(getCompoundedDebtDeposit1))
			const getCompoundedDebtDeposit2 = await StabilityPool.getCompoundedDebtDeposit(accounts[2])
			// console.log('getCompoundedDebtDeposit2', getCompoundedDebtDeposit2, formatEther(getCompoundedDebtDeposit2))
			const getCompoundedDebtDeposit3 = await StabilityPool.getCompoundedDebtDeposit(accounts[3])
			// console.log('getCompoundedDebtDeposit3', getCompoundedDebtDeposit3, formatEther(getCompoundedDebtDeposit3))
			const getDepositorCollateralGain0 = await StabilityPool.getDepositorCollateralGain(accounts[0])
			// console.log('getDepositorCollateralGain0', getDepositorCollateralGain0)
			const getDepositorCollateralGain1 = await StabilityPool.getDepositorCollateralGain(accounts[1])
			// console.log('getDepositorCollateralGain1', getDepositorCollateralGain1)
			const getDepositorCollateralGain2 = await StabilityPool.getDepositorCollateralGain(accounts[2])
			// console.log('getDepositorCollateralGain2', getDepositorCollateralGain2)
			const getDepositorCollateralGain3 = await StabilityPool.getDepositorCollateralGain(accounts[3])
			// console.log('getDepositorCollateralGain3', getDepositorCollateralGain3)
			await time.increase(365 * 24 * 3600)

		}

		{
			// console.log('liquidationIds2', liquidationIds2)
			await troveManager2.batchLiquidate(liquidationIds2.slice(0, 20))
			const getCompoundedDebtDeposit0 = await StabilityPool.getCompoundedDebtDeposit(accounts[0])
			// console.log('getCompoundedDebtDeposit0', getCompoundedDebtDeposit0, formatEther(getCompoundedDebtDeposit0))
			const getCompoundedDebtDeposit1 = await StabilityPool.getCompoundedDebtDeposit(accounts[1])
			// console.log('getCompoundedDebtDeposit1', getCompoundedDebtDeposit1, formatEther(getCompoundedDebtDeposit1))
			const getCompoundedDebtDeposit2 = await StabilityPool.getCompoundedDebtDeposit(accounts[2])
			// console.log('getCompoundedDebtDeposit2', getCompoundedDebtDeposit2, formatEther(getCompoundedDebtDeposit2))
			const getCompoundedDebtDeposit3 = await StabilityPool.getCompoundedDebtDeposit(accounts[3])
			// console.log('getCompoundedDebtDeposit3', getCompoundedDebtDeposit3, formatEther(getCompoundedDebtDeposit3))
			const getDepositorCollateralGain0 = await StabilityPool.getDepositorCollateralGain(accounts[0])
			// console.log('getDepositorCollateralGain0', getDepositorCollateralGain0)
			const getDepositorCollateralGain1 = await StabilityPool.getDepositorCollateralGain(accounts[1])
			// console.log('getDepositorCollateralGain1', getDepositorCollateralGain1)
			const getDepositorCollateralGain2 = await StabilityPool.getDepositorCollateralGain(accounts[2])
			// console.log('getDepositorCollateralGain2', getDepositorCollateralGain2)
			const getDepositorCollateralGain3 = await StabilityPool.getDepositorCollateralGain(accounts[3])
			// console.log('getDepositorCollateralGain3', getDepositorCollateralGain3)
			await time.increase(365 * 24 * 3600)

		}
		{
			const getCompoundedDebtDeposit0 = await StabilityPool.getCompoundedDebtDeposit(accounts[0])
			await StabilityPool.connect(signers[0]).withdrawFromSP(getCompoundedDebtDeposit0)
			const getCompoundedDebtDeposit1 = await StabilityPool.getCompoundedDebtDeposit(accounts[1])
			await StabilityPool.connect(signers[1]).withdrawFromSP(getCompoundedDebtDeposit1)
			const getCompoundedDebtDeposit2 = await StabilityPool.getCompoundedDebtDeposit(accounts[2])
			await StabilityPool.connect(signers[2]).withdrawFromSP(getCompoundedDebtDeposit2)
			const getCompoundedDebtDeposit3 = await StabilityPool.getCompoundedDebtDeposit(accounts[3])
			await StabilityPool.connect(signers[3]).withdrawFromSP(getCompoundedDebtDeposit3)
			const getDepositorCollateralGain0 = await StabilityPool.getDepositorCollateralGain(accounts[0])
			// console.log('getDepositorCollateralGain0', getDepositorCollateralGain0)
			const getDepositorCollateralGain1 = await StabilityPool.getDepositorCollateralGain(accounts[1])
			// console.log('getDepositorCollateralGain1', getDepositorCollateralGain1)
			const getDepositorCollateralGain2 = await StabilityPool.getDepositorCollateralGain(accounts[2])
			// console.log('getDepositorCollateralGain2', getDepositorCollateralGain2)
			const getDepositorCollateralGain3 = await StabilityPool.getDepositorCollateralGain(accounts[3])
			// console.log('getDepositorCollateralGain3', getDepositorCollateralGain3)
			await time.increase(365 * 24 * 3600)
			await StabilityPool.connect(signers[0]).claimAllCollateralGains(accounts[10])
			await StabilityPool.connect(signers[1]).claimAllCollateralGains(accounts[11])
			await StabilityPool.connect(signers[2]).claimAllCollateralGains(accounts[12])
			await StabilityPool.connect(signers[3]).claimAllCollateralGains(accounts[13])
		}
		const getYieldGains0 = await StabilityPool.getYieldGains(accounts[0])
		// console.log('getYieldGains0', formatEther(getYieldGains0))
		const getYieldGains1 = await StabilityPool.getYieldGains(accounts[1])
		// console.log('getYieldGains1', formatEther(getYieldGains1))
		const getYieldGains2 = await StabilityPool.getYieldGains(accounts[2])
		// console.log('getYieldGains2', formatEther(getYieldGains2))
		const getYieldGains3 = await StabilityPool.getYieldGains(accounts[3])
		// console.log('getYieldGains3', formatEther(getYieldGains3))
		await StabilityPool.connect(signers[0]).claimYield(accounts[10])
		// console.log('yield0', formatEther(await DebtToken.balanceOf(accounts[10])))
		await StabilityPool.connect(signers[1]).claimYield(accounts[11])
		// console.log('yield1', formatEther(await DebtToken.balanceOf(accounts[11])))
		await StabilityPool.connect(signers[2]).claimYield(accounts[12])
		// console.log('yield2', formatEther(await DebtToken.balanceOf(accounts[12])))
		await StabilityPool.connect(signers[3]).claimYield(accounts[13])
		// console.log('yield3', formatEther(await DebtToken.balanceOf(accounts[13])))
		// console.log('StabilityPool balance', formatEther(await DebtToken.balanceOf(StabilityPool.target)))

	})

})