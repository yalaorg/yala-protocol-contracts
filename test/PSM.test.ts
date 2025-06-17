import '@nomicfoundation/hardhat-ethers'
import { expect } from 'chai'
import { MaxUint256, parseEther, ZeroAddress } from 'ethers'
import { IFixture, loadFixture } from './fixture'
import { deployNewPSM } from './utils'

describe('Test PSM', () => {
	let fixture: IFixture

	beforeEach(async () => {
		fixture = await loadFixture()
	})

	it('initialize PSM', async () => {
		const { psm, pegToken } = await deployNewPSM(fixture)
		const feeIn = await psm.feeIn()
		const feeOut = await psm.feeOut()
		const supplyCap = await psm.supplyCap()

		expect(pegToken.target).to.not.equal(ZeroAddress)
		expect(feeIn).to.equal(parseEther('0.01'))
		expect(feeOut).to.equal(parseEther('0.02'))
		expect(supplyCap).to.equal(parseEther('10000000'))
	})

	it('buy debt tokens', async () => {
		const { DebtToken, account } = fixture
		const { psm, pegToken } = await deployNewPSM(fixture)
		await pegToken.approve(psm.target, MaxUint256)
		const pegAmount = parseEther('1000')
		const initialDebtBalance = await DebtToken.balanceOf(account)
		const { amountDebtTokenReceived } = await psm.estimateBuy(pegAmount)
		await psm.buy(pegAmount)
		const finalDebtBalance = await DebtToken.balanceOf(account)
		expect(finalDebtBalance - initialDebtBalance).to.be.eq(amountDebtTokenReceived)
	})

	it('sell debt tokens', async () => {
		const { DebtToken, account } = fixture
		const { psm, pegToken } = await deployNewPSM(fixture)

		// First buy some debt tokens
		await pegToken.transfer(account, parseEther('2000'))
		await pegToken.approve(psm.target, MaxUint256)
		await psm.buy(parseEther('1000'))

		await pegToken.transfer(psm.target, parseEther('2000'))

		// Now sell them
		await DebtToken.approve(psm.target, parseEther('2000'))
		const sellAmount = parseEther('5')
		const initialDebtBalance = await DebtToken.balanceOf(account)
		await psm.sell(sellAmount)

		const finalDebtBalance = await DebtToken.balanceOf(account)
		expect(initialDebtBalance - finalDebtBalance).to.be.eq(sellAmount)
	})

	it('respect supply cap', async () => {
		const { psm, pegToken } = await deployNewPSM(fixture, { supplyCap: parseEther('1000') })

		//await pegToken.mint(account, parseEther('2000'))
		await pegToken.approve(psm.target, MaxUint256)

		await expect(psm.buy(parseEther('1200'))).to.be.revertedWith(
			'PSM: Supply cap reached',
		)
	})

	it('update fees', async () => {
		const { psm } = await deployNewPSM(fixture)

		await psm.setFeeIn(parseEther('0.02'))
		await psm.setFeeOut(parseEther('0.03'))

		const feeIn = await psm.feeIn()
		const feeOut = await psm.feeOut()
		expect(feeIn).to.equal(parseEther('0.02'))
		expect(feeOut).to.equal(parseEther('0.03'))
	})

	it('update supply cap', async () => {
		const { psm } = await deployNewPSM(fixture)

		await psm.setSupplyCap(parseEther('20000000'))

		const supplyCap = await psm.supplyCap()
		expect(supplyCap).to.equal(parseEther('20000000'))
	})

	it('pause and unpause', async () => {
		const { psm, pegToken } = await deployNewPSM(fixture)

		//await pegToken.mint(account, parseEther('2000'))
		await pegToken.approve(psm.target, MaxUint256)

		await psm.pause()
		await expect(psm.buy(parseEther('100'))).to.be.revertedWith(
			'Pausable: paused',
		)

		await psm.unpause()
		await expect(psm.buy(parseEther('100'))).to.not.be.reverted
	})

	it('check totalActivedebt', async () => {
		const { DebtToken, account } = fixture
		const { psm, pegToken } = await deployNewPSM(fixture)

		await pegToken.transfer(account, parseEther('2000'))
		await pegToken.approve(psm.target, MaxUint256)

		const buyAmount = parseEther('1000')
		await psm.buy(buyAmount)
		const { amountDebtTokenReceived, fee } = await psm.estimateBuy(buyAmount)
		let totalActivedebt = await psm.totalActivedebt()
		expect(totalActivedebt).to.equal(amountDebtTokenReceived + fee)

		const sellAmount = parseEther('500')
		await DebtToken.approve(psm.target, MaxUint256)
		await psm.sell(sellAmount)

		totalActivedebt = await psm.totalActivedebt()
		expect(totalActivedebt).to.equal(amountDebtTokenReceived + fee - sellAmount)
	})
})
