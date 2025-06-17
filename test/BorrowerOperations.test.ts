import '@nomicfoundation/hardhat-ethers'
import { loadFixture, IFixture } from './fixture'
import { expect } from 'chai'
import { formatEther, MaxUint256, parseEther } from 'ethers'
import { time } from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { deployNewCDP, openTrove } from './utils'
import { ethers } from 'hardhat'

describe('Test BorrowerOperations', () => {
	let fixture: IFixture

	beforeEach(async () => {
		fixture = await loadFixture()
	})

	it('open trove', async () => {
		const { BorrowerOperations, MockCollateralToken, MockPriceFeed, account } = fixture
		const troveManager = await deployNewCDP(fixture)
		await MockCollateralToken.approve(BorrowerOperations.target, MaxUint256)
		// min net debt not reached
		await expect(BorrowerOperations.openTrove(troveManager.target, account, parseEther('1'), parseEther('1000'))).to.be.reverted
		// cr not reached
		await expect(BorrowerOperations.openTrove(troveManager.target, account, parseEther('1'), parseEther('1800'))).to.be.reverted
		const price = parseEther('100000')
		await MockPriceFeed.updatePrice(MockCollateralToken.target, price)
		await BorrowerOperations.openTrove(troveManager.target, account, parseEther('1'), parseEther('1800'))
		const TCR = await troveManager.getTCR.staticCall()
		// console.log('TCR', formatEther(TCR))
		// 100000 * 1 / (1800+200)
		expect(TCR).to.be.eq(parseEther('50'))
		const ICR = await troveManager.getCurrentICR.staticCall(0, price)
		// only one Trove
		expect(ICR).to.be.eq(TCR)
		await MockPriceFeed.updatePrice(MockCollateralToken.target, parseEther('2999'))
		const newTCR = await troveManager.getTCR.staticCall()
		expect(newTCR).to.be.lt(await troveManager.CCR())
		await expect(BorrowerOperations.openTrove(troveManager.target, account, parseEther('1'), parseEther('1800'))).to.be.reverted
		await BorrowerOperations.openTrove(troveManager.target, account, parseEther('1.01'), parseEther('1800'))
	})

	it('add coll', async () => {
		const { troveManager, id } = await openTrove(fixture)
		const { BorrowerOperations } = fixture
		await BorrowerOperations.addColl(troveManager.target, id, parseEther('1'))
		const newTCR = await troveManager.getTCR.staticCall()
		// console.log('newTCR', formatEther(newTCR))
	})

	it('withdraw coll', async () => {
		const { troveManager, id } = await openTrove(fixture)
		const { BorrowerOperations } = fixture
		await BorrowerOperations.withdrawColl(troveManager.target, id, parseEther('0.2'))
		const newTCR = await troveManager.getTCR.staticCall()
		// console.log('newTCR', formatEther(newTCR))
	})

	it('withdraw debt', async () => {
		const { troveManager, id } = await openTrove(fixture)
		const { BorrowerOperations } = fixture
		await BorrowerOperations.withdrawDebt(troveManager.target, id, parseEther('2000'))
		const newTCR = await troveManager.getTCR.staticCall()
		// console.log('newTCR', formatEther(newTCR))
	})

	it('repay', async () => {
		const { troveManager, id } = await openTrove(fixture, { debt: parseEther('4800') })
		const { BorrowerOperations } = fixture
		await time.increase(24 * 3600 * 365)
		// anyonw can pay a trove
		await BorrowerOperations.repay(troveManager.target, id, parseEther('500'))
		await BorrowerOperations.repay(troveManager.target, id, parseEther('500'))
		const debtRepaidTrove = await troveManager.Troves(id)
		expect(debtRepaidTrove.debt).to.be.gt(0n)
		expect(debtRepaidTrove.interest).to.be.gt(0n)
		await BorrowerOperations.repay(troveManager.target, id, parseEther('2000'))
		const trove = await troveManager.Troves(id)
		expect(trove.debt).to.be.eq(parseEther('2000'))
		expect(trove.interest).to.be.gt(0n)
		await BorrowerOperations.repay(troveManager.target, id, parseEther('501'))
		const interestRepaidTrove = await troveManager.Troves(id)
		expect(interestRepaidTrove.debt).to.be.eq(parseEther('2000'))
		expect(interestRepaidTrove.interest).to.be.eq(0n)
	})

	it('close trove', async () => {
		const troveManager = await deployNewCDP(fixture, { spYieldPCT: 0n })
		const { id } = await openTrove(fixture, { debt: parseEther('4800'), troveManager })
		const { id: id2 } = await openTrove(fixture, { debt: parseEther('9800'), troveManager })
		const { BorrowerOperations, accounts, signers, DebtToken, MockCollateralToken } = fixture
		await time.increase(24 * 3600 * 365)
		await BorrowerOperations.closeTrove(troveManager, id, accounts[1])
		const coll = await MockCollateralToken.balanceOf(accounts[1])
		expect(coll).to.be.eq(parseEther('1'))
		await troveManager.setApprovalForAll(accounts[2], true)
		await DebtToken.transfer(accounts[2], await DebtToken.balanceOf(accounts[0]))
		await BorrowerOperations.connect(signers[2]).closeTrove(troveManager, id2, accounts[2])
		const totalSupply = await troveManager.totalSupply()
		expect(totalSupply).to.be.eq(0n)
	})

	it('adjust trove', async () => {
		const troveManager = await deployNewCDP(fixture, { spYieldPCT: 0n })
		const { id } = await openTrove(fixture, { debt: parseEther('4800'), troveManager })
		await openTrove(fixture, { debt: parseEther('9800'), troveManager })
		const { BorrowerOperations, MockPriceFeed, MockCollateralToken } = fixture
		await time.increase(24 * 3600 * 365)
		const TCR = await troveManager.getTCR.staticCall()
		// add coll
		await BorrowerOperations.adjustTrove(troveManager.target, id, parseEther('1'), 0, 0, false)
		// withdraw coll
		await BorrowerOperations.adjustTrove(troveManager.target, id, 0, parseEther('1'), 0, false)
		// withdraw debt
		await BorrowerOperations.adjustTrove(troveManager.target, id, 0, 0, parseEther('20000'), true)
		// repay debt
		await BorrowerOperations.adjustTrove(troveManager.target, id, 0, 0, parseEther('20000'), false)
		// TCR < CCR
		const price = parseEther('12000')
		await MockPriceFeed.updatePrice(MockCollateralToken.target, price)
		const newTCR = await troveManager.getTCR.staticCall()
		expect(newTCR).to.be.lt(await troveManager.CCR())
		await expect(BorrowerOperations.adjustTrove(troveManager.target, id, 0, 0, parseEther('20000'), true)).to.be.reverted
		await expect(BorrowerOperations.adjustTrove(troveManager.target, id, 0, parseEther('0.1'), parseEther('1199'), false)).to.be.reverted
		await BorrowerOperations.adjustTrove(troveManager.target, id, 0, parseEther('0.1'), parseEther('1200'), false)

	})

	it('multi collateral', async () => {
		const { signer, account, MockCollateralToken, BorrowerOperations } = fixture
		const newCollateral = await ethers.deployContract('MockCollateralToken', signer)
		const troveManager0 = await deployNewCDP(fixture, { spYieldPCT: 0n }, { collateralToken: MockCollateralToken.target, })
		const troveManager1 = await deployNewCDP(fixture, { spYieldPCT: 0n }, { collateralToken: newCollateral.target })
		const { id: id0 } = await openTrove(fixture, { debt: parseEther('4800'), coll: parseEther('1'), price: parseEther('100000'), troveManager: troveManager0 })
		const { id: id1 } = await openTrove(fixture, { debt: parseEther('9800'), coll: parseEther('100'), price: parseEther('5000'), troveManager: troveManager1 })
		await time.increase(24 * 3600 * 365)
		const { id: id2 } = await openTrove(fixture, { debt: parseEther('4800'), coll: parseEther('1'), price: parseEther('100000'), troveManager: troveManager0 })
		await time.increase(24 * 3600 * 365)
		const { id: id3 } = await openTrove(fixture, { debt: parseEther('4800'), coll: parseEther('1'), price: parseEther('100000'), troveManager: troveManager0 })
		await BorrowerOperations.closeTrove(troveManager0, id0, account)
		await BorrowerOperations.closeTrove(troveManager0, id2, account)
		await BorrowerOperations.closeTrove(troveManager0, id3, account)
		const totalSupply = await troveManager0.totalSupply()
		expect(totalSupply).to.be.eq(0n)
	})

})