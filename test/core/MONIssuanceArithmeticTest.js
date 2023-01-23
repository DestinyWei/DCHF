const Decimal = require('decimal.js')
const deploymentHelper = require('../utils/deploymentHelpers.js')
const { BNConverter } = require('../utils/BNConverter.js')
const testHelpers = require('../utils/testHelpers.js')
const StabilityPool = artifacts.require('./StabilityPool.sol')

const th = testHelpers.TestHelper
const timeValues = testHelpers.TimeValues
const dec = th.dec
const toBN = th.toBN

const logMONBalanceAndError = (MONBalance_A, expectedMONBalance_A) => {
  console.log(
    `Expected final balance: ${expectedMONBalance_A}, \n
    Actual final balance: ${MONBalance_A}, \n
    Abs. error: ${expectedMONBalance_A.sub(MONBalance_A)}`
  )
}

const repeatedlyIssueMON = async (stabilityPool, timeBetweenIssuances, duration) => {
  const startTimestamp = th.toBN(await th.getLatestBlockTimestamp(web3))
  let timePassed = 0

  // while current time < 1 month from deployment, issue MON every minute
  while (timePassed < duration) {
    await th.fastForwardTime(timeBetweenIssuances, web3.currentProvider)
    await stabilityPool._unprotectedTriggerMONIssuance()

    const currentTimestamp = th.toBN(await th.getLatestBlockTimestamp(web3))
    timePassed = currentTimestamp.sub(startTimestamp)
  }
}

contract('MON community issuance arithmetic tests', async (accounts) => {
  const ZERO_ADDRESS = th.ZERO_ADDRESS
  let contracts
  let borrowerOperations
  let communityIssuanceTester
  let MONToken
  let stabilityPool
  let stabilityPoolERC20
  let erc20
  let ratePerMinute

  const [owner, alice, frontEnd_1] = accounts

  const [bountyAddress, lpRewardsAddress, multisig] = accounts.slice(997, 1000)

  const ERC_WEEKLY = dec(500, 18)
  const ETH_WEEKLY = dec(1000, 18)

  // using the result of this to advance time by the desired amount from the deployment time, whether or not some extra time has passed in the meanwhile
  const getDuration = async (expectedDuration) => {
    const deploymentTimeETH = (await communityIssuanceTester.lastUpdateTime(stabilityPool.address)).toNumber()
    const deploymentTimeERC20 = (
      await communityIssuanceTester.lastUpdateTime(stabilityPoolERC20.address)
    ).toNumber()
    const deploymentTime = Math.max(deploymentTimeETH, deploymentTimeERC20)
    const currentTime = await th.getLatestBlockTimestamp(web3)
    const duration = Math.max(expectedDuration - (currentTime - deploymentTime), 0)

    return duration
  }

  beforeEach(async () => {
    contracts = await deploymentHelper.deployLiquityCore()
    const MONContracts = await deploymentHelper.deployMONContractsHardhat(accounts[0])
    contracts = await deploymentHelper.deployDCHFToken(contracts)

    borrowerOperations = contracts.borrowerOperations
    erc20 = contracts.erc20

    MONToken = MONContracts.monToken
    communityIssuanceTester = MONContracts.communityIssuance

    await deploymentHelper.connectCoreContracts(contracts, MONContracts)
    await deploymentHelper.connectMONContractsToCore(MONContracts, contracts)
    stabilityPool = await StabilityPool.at(
      await contracts.stabilityPoolManager.getAssetStabilityPool(ZERO_ADDRESS)
    )
    stabilityPoolERC20 = await StabilityPool.at(
      await contracts.stabilityPoolManager.getAssetStabilityPool(erc20.address)
    )

    await communityIssuanceTester.setWeeklyDfrancDistribution(stabilityPool.address, ETH_WEEKLY)
    await communityIssuanceTester.setWeeklyDfrancDistribution(stabilityPoolERC20.address, ERC_WEEKLY)
  })

  it('Cumulative issuance is correct after a week', async () => {
    const initialIssuance = await communityIssuanceTester.getLastUpdateTokenDistribution(
      stabilityPool.address
    )
    const initialIssuanceERC20 = await communityIssuanceTester.getLastUpdateTokenDistribution(
      stabilityPoolERC20.address
    )
    await th.fastForwardTime(timeValues.MINUTES_IN_ONE_WEEK, web3.currentProvider)

    const issuanceFractionAfter = await communityIssuanceTester.getLastUpdateTokenDistribution(
      stabilityPool.address
    )
    const issuanceFractionAfterERC20 = await communityIssuanceTester.getLastUpdateTokenDistribution(
      stabilityPoolERC20.address
    )
    assert.isAtMost(
      th.getDifferenceEther(issuanceFractionAfter, initialIssuance),
      th.toUnitNumber(ETH_WEEKLY)
    )
    assert.isAtMost(
      th.getDifferenceEther(issuanceFractionAfterERC20, initialIssuanceERC20),
      th.toUnitNumber(ERC_WEEKLY)
    )
  })

  it('Cumulative issuance is correct after two week', async () => {
    await th.fastForwardTime(timeValues.MINUTES_IN_ONE_WEEK * 2, web3.currentProvider)

    const issuanceFractionAfter = await communityIssuanceTester.getLastUpdateTokenDistribution(
      stabilityPool.address
    )
    const issuanceFractionAfterERC20 = await communityIssuanceTester.getLastUpdateTokenDistribution(
      stabilityPoolERC20.address
    )
    assert.isAtMost(issuanceFractionAfter.div(toBN(ETH_WEEKLY).mul(toBN(2))).toNumber(), 2)
    assert.isAtMost(issuanceFractionAfterERC20.div(toBN(ERC_WEEKLY).mul(toBN(2))).toNumber(), 2)
  })

  it('Give full supply after 4 weeks, forwards 4 weeks, totalIssueMON should be max supply', async () => {
    await communityIssuanceTester.setWeeklyDfrancDistribution(stabilityPool.address, dec(32_000_000 / 4, 18))

    await th.fastForwardTime(
      toBN(timeValues.SECONDS_IN_ONE_WEEK).mul(toBN(4).add(toBN(120))),
      web3.currentProvider
    )

    await communityIssuanceTester.unprotectedIssueMON(stabilityPool.address)
    const totalIssued = await communityIssuanceTester.totalMONIssued(stabilityPool.address)
    assert.equal(totalIssued.toString(), dec(32_000_000, 18))
  })

  it('Give full supply after 4 weeks, forwards 8 weeks, totalIssueMON should be max supply', async () => {
    await communityIssuanceTester.setWeeklyDfrancDistribution(stabilityPool.address, dec(32_000_000 / 4, 18))

    await th.fastForwardTime(toBN(timeValues.SECONDS_IN_ONE_WEEK).mul(toBN(8)), web3.currentProvider)

    await communityIssuanceTester.unprotectedIssueMON(stabilityPool.address)
    const totalIssued = await communityIssuanceTester.totalMONIssued(stabilityPool.address)
    assert.equal(totalIssued.toString(), dec(32_000_000, 18))
  })

  // // --- Token issuance for yearly halving ---

  it('Total MON tokens issued is correct after a week', async () => {
    const distribution = toBN(dec(8_000_000, 18))
    const expectedReward = distribution

    await communityIssuanceTester.setWeeklyDfrancDistribution(stabilityPool.address, distribution)
    await communityIssuanceTester.setWeeklyDfrancDistribution(stabilityPoolERC20.address, distribution)

    const initialIssuance = await communityIssuanceTester.totalMONIssued(stabilityPool.address)
    assert.equal(initialIssuance, 0)

    const initialIssuanceERC20 = await communityIssuanceTester.totalMONIssued(stabilityPoolERC20.address)
    assert.equal(initialIssuanceERC20, 0)

    // Fast forward time
    await th.fastForwardTime(timeValues.SECONDS_IN_ONE_WEEK, web3.currentProvider)

    // Issue MON
    await communityIssuanceTester.unprotectedIssueMON(stabilityPool.address)
    const totalMONIssued = await communityIssuanceTester.totalMONIssued(stabilityPool.address)

    await communityIssuanceTester.unprotectedIssueMON(stabilityPoolERC20.address)
    const totalMONIssuedERC20 = await communityIssuanceTester.totalMONIssued(stabilityPoolERC20.address)

    assert.isAtMost(th.getDifference(totalMONIssued, expectedReward), 1000000000000000)
    assert.isAtMost(th.getDifference(totalMONIssuedERC20, expectedReward), 1000000000000000)
  })

  it('Total MON tokens issued is correct after a month', async () => {
    const distribution = toBN(dec(8_000_000, 18))
    await communityIssuanceTester.setWeeklyDfrancDistribution(stabilityPool.address, distribution)
    await communityIssuanceTester.setWeeklyDfrancDistribution(
      stabilityPoolERC20.address,
      dec(distribution.toString(), 18)
    )

    const initialIssuance = await communityIssuanceTester.totalMONIssued(stabilityPool.address)
    assert.equal(initialIssuance, 0)

    const initialIssuanceERC20 = await communityIssuanceTester.totalMONIssued(stabilityPoolERC20.address)
    assert.equal(initialIssuanceERC20, 0)

    // Fast forward time
    await th.fastForwardTime(timeValues.SECONDS_IN_ONE_MONTH, web3.currentProvider)

    // Issue MON
    await communityIssuanceTester.unprotectedIssueMON(stabilityPool.address)
    const totalMONIssued = await communityIssuanceTester.totalMONIssued(stabilityPool.address)

    await communityIssuanceTester.unprotectedIssueMON(stabilityPoolERC20.address)
    const totalMONIssuedERC20 = await communityIssuanceTester.totalMONIssued(stabilityPoolERC20.address)

    assert.isAtMost(th.getDifference(totalMONIssued, distribution.mul(toBN(4))), 1000000000000000)
    assert.isAtMost(th.getDifference(totalMONIssuedERC20, distribution.mul(toBN(4))), 1000000000000000)
  })
})