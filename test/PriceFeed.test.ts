import '@nomicfoundation/hardhat-ethers'
import { loadFixture, IFixture } from './fixture'
import { time } from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { updateMockAggregatorV3Price } from './utils'
import { parseUnits } from 'ethers'
import { ethers } from 'hardhat'

describe('Test PriceFeed', () => {
	let fixture: IFixture

	beforeEach(async () => {
		fixture = await loadFixture()
	})

	it('fetchPrice', async () => {
		const { PriceFeed, MockCollateralToken, MockAggregatorV3Interface } = fixture
		await PriceFeed.fetchPrice.staticCall(MockCollateralToken.target)
		await time.increase(7200)
		// feed frozen
		await expect(PriceFeed.fetchPrice(MockCollateralToken.target)).to.be.reverted
		const newPrice = parseUnits('90000', 8)
		await updateMockAggregatorV3Price(MockAggregatorV3Interface, 101, newPrice)
		expect(await PriceFeed.fetchPrice.staticCall(MockCollateralToken.target)).to.be.eq(newPrice * (10n ** 10n))
	})

	it('set new oracle', async () => {
		const { signer, PriceFeed } = fixture
		const newCollateraToken = await ethers.deployContract('MockCollateralToken', signer)
		const newMockAggregatorV3Interface = await ethers.deployContract('MockAggregatorV3Interface', [signer.address], signer)
		await expect(PriceFeed.setOracle(newCollateraToken.target, newMockAggregatorV3Interface.target, 3600)).to.be.reverted
		const price = parseUnits('10000', 8)
		await updateMockAggregatorV3Price(newMockAggregatorV3Interface, 100, price)
		await PriceFeed.setOracle(newCollateraToken.target, newMockAggregatorV3Interface.target, 3600)
		expect(await PriceFeed.fetchPrice.staticCall(newCollateraToken.target)).to.be.eq(price * (10n ** 10n))

	})

})