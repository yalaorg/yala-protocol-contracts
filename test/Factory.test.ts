import '@nomicfoundation/hardhat-ethers'
import { loadFixture, IFixture } from './fixture'
import { deployNewCDP, deployNewPSM } from './utils'

describe('Test Factory', () => {
	let fixture: IFixture

	beforeEach(async () => {
		fixture = await loadFixture()
	})

	it('deployNewCDP', async () => {
		await deployNewCDP(fixture)
	})

	it('deployNewPSM', async () => {
		await deployNewPSM(fixture)
	})

})